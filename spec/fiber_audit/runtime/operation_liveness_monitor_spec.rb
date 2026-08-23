# frozen_string_literal: true

require 'json'
require 'stringio'
require 'fiber_audit/runtime/operation_liveness_monitor'

RSpec.describe FiberAudit::Runtime::OperationLivenessMonitor do
  let(:session_id) { '123e4567-e89b-42d3-a456-426614174000' }

  def build_monitor(enabled: true, fail_open: true, snapshot_limit: 100,
                    thread_factory: ->(&block) { Thread.new(&block) })
    now = 0
    io = StringIO.new
    runtime_policy = FiberAudit::Runtime::Policy.new(sampling_rate: 0.0, fail_open: fail_open,
                                                     max_events_per_second: 100,
                                                     max_events_per_session: 1_000)
    clock = FiberAudit::Runtime::Clock.new(wall: -> { Time.utc(2026, 8, 2, 12) }, monotonic: -> { now })
    session = FiberAudit::Runtime::Session.new(id: session_id, started_at: Time.utc(2026, 8, 2, 12),
                                               started_monotonic_ns: 0, policy: runtime_policy)
    writer = FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: runtime_policy.max_record_bytes)
    recorder = FiberAudit::Runtime::Recorder.start(session: session, writer: writer, clock: clock)
    operations = FiberAudit::Runtime::ActiveOperations.new(snapshot_limit: snapshot_limit)
    policy = FiberAudit::Runtime::OperationLivenessPolicy.new(enabled: enabled, poll_interval_ms: 60_000,
                                                              long_active_threshold_ms: 1_000)
    monitor = described_class.new(policy: policy, recorder: recorder, active_operations: operations,
                                  clock: clock, thread_factory: thread_factory)
    [monitor, recorder, operations, io, ->(value) { now = value }]
  end

  def event_payloads(io)
    io.string.lines.map { |line| JSON.parse(line) }
                   .select { |record| record['record_type'] == 'event' }
                   .map { |record| record.fetch('payload') }
  end

  def register(operations, monotonic_ns: 0, line: 1, scheduler_snapshot: nil)
    operations.register(operation: 'Mutex#lock',
                        location: FiberAudit::Runtime::Location.new(path: 'app/task.rb', line: line),
                        execution_context: :job, monotonic_ns: monotonic_ns,
                        scheduler_snapshot: scheduler_snapshot)
  end

  it 'uses the injected thread factory and emits explicit states without sampling' do
    calls = 0
    factory = lambda do |&block|
      calls += 1
      Thread.new(&block)
    end
    active, active_recorder, _operations, active_io, = build_monitor(thread_factory: factory)
    disabled, disabled_recorder, _disabled_operations, disabled_io, = build_monitor(enabled: false)

    active.stop
    disabled.stop
    active_recorder.close
    disabled_recorder.close

    expect(calls).to eq(1)
    expect(event_payloads(active_io).map { |payload| payload['kind'] }).to include('operation_liveness_active')
    expect(event_payloads(disabled_io).map { |payload| payload['kind'] }).to eq(['operation_liveness_disabled'])
  end

  it 'uses an exclusive threshold and emits one start/completion pair' do
    monitor, recorder, operations, io, = build_monitor
    handle = register(operations)
    monitor.poll(now_ns: 1_000_000_000)
    monitor.poll(now_ns: 1_000_000_001)
    monitor.poll(now_ns: 1_100_000_000)
    operations.finish(handle)
    monitor.poll(now_ns: 1_200_000_000)

    events = event_payloads(io)
    started = events.select { |payload| payload['kind'] == 'operation_long_active_started' }
    completed = events.select { |payload| payload['kind'] == 'operation_long_active_completed' }
    expect(started.size).to eq(1)
    expect(completed.size).to eq(1)
    expect(completed.first.dig('measurements', 'operation_finished')).to be(true)
    expect(completed.first.dig('measurements', 'long_active_sequence'))
      .to eq(started.first.dig('measurements', 'long_active_sequence'))
  ensure
    monitor&.stop
    recorder&.close unless recorder&.closed?
  end

  it 'bounds new starts per poll and makes truncation visible' do
    monitor, recorder, operations, io, = build_monitor
    15.times { |index| register(operations, line: index + 1) }
    monitor.poll(now_ns: 1_000_000_001)
    starts = event_payloads(io).select { |payload| payload['kind'] == 'operation_long_active_started' }

    expect(starts.size).to eq(10)
    expect(starts).to all(satisfy do |payload|
      payload.dig('measurements', 'long_active_batch_truncated') == true &&
        payload.dig('measurements', 'long_active_candidate_count') == 15
    end)
  ensure
    monitor&.stop
    recorder&.close unless recorder&.closed?
  end

  it 'marks registry truncation and preserves unknown scheduler state' do
    monitor, recorder, operations, io, = build_monitor(snapshot_limit: 1)
    unknown = FiberAudit::Runtime::SchedulerSnapshot.new(scheduler_present: nil, fiber_blocking: nil)
    register(operations, scheduler_snapshot: unknown)
    register(operations, line: 2)
    monitor.poll(now_ns: 1_000_000_001)
    start = event_payloads(io).find { |payload| payload['kind'] == 'operation_long_active_started' }

    expect(start.dig('measurements', 'active_operation_snapshot_truncated')).to be(true)
    expect(start.dig('measurements', 'active_operation_total_count')).to eq(2)
    expect(start.dig('measurements', 'scheduler_present')).to be_nil
    expect(start.dig('measurements', 'fiber_blocking')).to be_nil
  ensure
    monitor&.stop
    recorder&.close unless recorder&.closed?
  end

  it 'adds the same scalar scheduler classification to both long-active events' do
    monitor, recorder, operations, io, = build_monitor
    snapshot = FiberAudit::Runtime::SchedulerSnapshot.new(
      scheduler_present: true,
      fiber_blocking: false
    )
    handle = register(operations, scheduler_snapshot: snapshot)
    monitor.poll(now_ns: 1_000_000_001)
    operations.finish(handle)
    monitor.poll(now_ns: 1_100_000_000)

    classified = event_payloads(io).select do |payload|
      %w[operation_long_active_started operation_long_active_completed].include?(payload['kind'])
    end
    expect(classified.size).to eq(2)
    classified.each do |payload|
      expect(payload.fetch('measurements')).to include(
        'operation_wait_possible' => true,
        'operation_inventory_only' => false,
        'operation_scheduler_capability_required' => true,
        'operation_scheduler_capability_supported' => true,
        'operation_scheduler_cooperation_available' => true
      )
    end
  ensure
    monitor&.stop
    recorder&.close unless recorder&.closed?
  end

  it 'closes an observed pair at shutdown without claiming operation completion' do
    monitor, recorder, operations, io, set_now = build_monitor
    register(operations)
    monitor.poll(now_ns: 1_000_000_001)
    set_now.call(1_500_000_000)
    2.times { monitor.stop }
    recorder.close

    completion = event_payloads(io).find { |payload| payload['kind'] == 'operation_long_active_completed' }
    expect(completion.dig('measurements', 'operation_finished')).to be(false)
  end

  it 'degrades fail-open failures and raises fail-closed failures without retaining messages' do
    open_monitor, open_recorder, open_operations, open_io, = build_monitor
    register(open_operations, monotonic_ns: 100)
    expect(open_monitor.poll(now_ns: 99)).to eq(:unsupported)
    open_monitor.stop
    expect(open_recorder.close.internal_errors).to be_positive
    expect(open_io.string).not_to include('moved backwards')

    closed_monitor, closed_recorder, closed_operations, _closed_io, = build_monitor(fail_open: false)
    register(closed_operations, monotonic_ns: 100)
    expect { closed_monitor.poll(now_ns: 99) }.to raise_error(FiberAudit::RuntimeSafetyError, /moved backwards/)
  ensure
    closed_monitor&.stop
    closed_recorder&.close unless closed_recorder&.closed?
  end
end
