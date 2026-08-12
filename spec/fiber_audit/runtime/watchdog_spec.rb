# frozen_string_literal: true

require 'json'
require 'stringio'
require 'fiber_audit/runtime/watchdog'

RSpec.describe FiberAudit::Runtime::Watchdog do
  let(:session_id) { '123e4567-e89b-42d3-a456-426614174000' }

  def build_runtime(sampling_rate: 0.0, fail_open: true, watchdog_values: {})
    now = 0
    io = StringIO.new
    runtime_policy = FiberAudit::Runtime::Policy.new(
      sampling_rate: sampling_rate,
      fail_open: fail_open,
      max_events_per_second: 100,
      max_events_per_session: 1_000
    )
    clock = FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12) },
      monotonic: -> { now }
    )
    session = FiberAudit::Runtime::Session.new(
      id: session_id,
      started_at: Time.utc(2026, 8, 2, 12),
      started_monotonic_ns: 0,
      policy: runtime_policy
    )
    writer = FiberAudit::Runtime::JSONL::Writer.new(
      io: io,
      max_record_bytes: runtime_policy.max_record_bytes
    )
    recorder = FiberAudit::Runtime::Recorder.start(
      session: session,
      writer: writer,
      clock: clock,
      random: -> { 0.99 }
    )
    operations = FiberAudit::Runtime::ActiveOperations.new
    watchdog = described_class.new(
      policy: FiberAudit::Runtime::WatchdogPolicy.new(**watchdog_values),
      recorder: recorder,
      redactor: FiberAudit::Runtime::Redactor.new(root: Dir.pwd, policy: runtime_policy),
      active_operations: operations,
      clock: clock,
      thread_factory: ->(&_block) { Thread.new { Thread.pass } }
    )
    set_now = ->(value) { now = value }
    [watchdog, recorder, operations, io, set_now]
  end

  def attach_heartbeat(watchdog, thread: Thread.current)
    fibers = []
    schedule = lambda do |&block|
      fiber = Fiber.new(&block)
      fibers << fiber
      fiber.resume
      fiber
    end
    watchdog.scheduler_installed(thread: thread, schedule: schedule, sleeper: ->(_seconds) { Fiber.yield })
    fibers.first
  end

  def event_payloads(io)
    io.string.lines
      .map { |line| JSON.parse(line) }
      .select { |record| record['record_type'] == 'event' }
      .map { |record| record.fetch('payload') }
  end

  it 'reports disabled and absent states explicitly without starting a thread' do
    disabled, disabled_recorder, = build_runtime(watchdog_values: { enabled: false })
    expect(disabled.state).to eq(:disabled)
    disabled.stop
    disabled_recorder.close

    absent, absent_recorder, _operations, io, = build_runtime
    expect(absent.state).to eq(:absent)
    absent.stop
    absent_recorder.close

    expect(event_payloads(io).map { |payload| payload['kind'] }).to eq(%w[watchdog_absent])
  end

  it 'emits active state even when ordinary event sampling is zero' do
    watchdog, recorder, _operations, io, = build_runtime(sampling_rate: 0.0)
    heartbeat = attach_heartbeat(watchdog)

    expect(watchdog.state).to eq(:active)
    watchdog.stop
    heartbeat.resume if heartbeat.alive?
    summary = recorder.close

    expect(event_payloads(io).map { |payload| payload['kind'] })
      .to include('watchdog_absent', 'watchdog_active')
    expect(summary.sampled_out).to eq(0)
  end

  it 'tracks scheduler channels independently across threads' do
    watchdog, recorder, = build_runtime
    other_thread = Thread.new { Thread.stop }
    first = attach_heartbeat(watchdog)
    second = attach_heartbeat(watchdog, thread: other_thread)

    watchdog.scheduler_closing(thread: Thread.current)
    expect(watchdog.state).to eq(:active)
    watchdog.scheduler_closing(thread: other_thread)
    expect(watchdog.state).to eq(:absent)

    watchdog.stop
    first.resume if first.alive?
    second.resume if second.alive?
    other_thread.kill.join
    recorder.close
  end

  it 'uses an exclusive threshold and emits one start/completion pair per stall' do
    watchdog, recorder, _operations, io, set_now = build_runtime(
      watchdog_values: { heartbeat_interval_ms: 25, stall_threshold_ms: 100, max_frames: 0 }
    )
    set_now.call(10)
    heartbeat = attach_heartbeat(watchdog)

    watchdog.poll(now_ns: 100_000_010)
    expect(event_payloads(io).map { |payload| payload['kind'] }).not_to include('scheduler_stall_started')

    watchdog.poll(now_ns: 100_000_011)
    watchdog.poll(now_ns: 150_000_000)
    set_now.call(160_000_000)
    heartbeat.resume
    watchdog.poll(now_ns: 160_000_000)

    kinds = event_payloads(io).map { |payload| payload['kind'] }
    expect(kinds.count('scheduler_stall_started')).to eq(1)
    expect(kinds.count('scheduler_stall_completed')).to eq(1)
    completion = event_payloads(io).find { |payload| payload['kind'] == 'scheduler_stall_completed' }
    expect(completion.fetch('measurements').fetch('resumed')).to be(true)

    watchdog.stop
    heartbeat.resume if heartbeat.alive?
    recorder.close
  end

  it 'can observe a later independent stall after progress resumes' do
    watchdog, recorder, _operations, io, set_now = build_runtime(watchdog_values: { max_frames: 0 })
    set_now.call(1)
    heartbeat = attach_heartbeat(watchdog)
    watchdog.poll(now_ns: 100_000_002)
    set_now.call(110_000_000)
    heartbeat.resume
    watchdog.poll(now_ns: 110_000_000)
    watchdog.poll(now_ns: 210_000_001)

    expect(event_payloads(io).count { |payload| payload['kind'] == 'scheduler_stall_started' }).to eq(2)

    watchdog.stop
    heartbeat.resume if heartbeat.alive?
    recorder.close
  end

  it 'bounds frames to safe project-relative locations and associates active operation sequences' do
    watchdog, recorder, operations, io, set_now = build_runtime(watchdog_values: { max_frames: 3 })
    set_now.call(10)
    heartbeat = attach_heartbeat(watchdog)
    operations.register(
      operation: 'Mutex#lock',
      location: FiberAudit::Runtime::Location.new(path: 'app/task.rb', line: 1),
      execution_context: :job,
      monotonic_ns: 20,
      thread: Thread.current,
      fiber: Fiber.current
    )

    watchdog.poll(now_ns: 100_000_011)
    payloads = event_payloads(io)
    start = payloads.find { |payload| payload['kind'] == 'scheduler_stall_started' }
    frames = payloads.select { |payload| payload['kind'] == 'scheduler_stall_frame' }

    expect(frames.size).to be <= 3
    expect(frames.map { |payload| payload.dig('location', 'path') }).to all(satisfy do |path|
      path && !path.start_with?('/') && !FiberAudit::Runtime::Location::SENTINELS.include?(path)
    end)
    expect(start.dig('measurements', 'active_operation_count')).to eq(1)
    expect(start.dig('measurements', 'active_operation_first_sequence')).to eq(1)
    overlap = payloads.find { |payload| payload['kind'] == 'scheduler_stall_operation_overlap' }
    expect(overlap['operation']).to eq('Mutex#lock')

    watchdog.stop
    heartbeat.resume if heartbeat.alive?
    recorder.close
  end

  it 'treats a dead scheduler thread with no backtrace as zero safe frames' do
    watchdog, recorder, _operations, io, set_now = build_runtime(watchdog_values: { max_frames: 5 })
    dead_thread = Thread.new { Thread.pass }
    dead_thread.join
    set_now.call(10)
    heartbeat = attach_heartbeat(watchdog, thread: dead_thread)

    watchdog.poll(now_ns: 100_000_011)
    start = event_payloads(io).find { |payload| payload['kind'] == 'scheduler_stall_started' }

    expect(start.dig('measurements', 'frame_count')).to eq(0)
    expect(event_payloads(io).none? { |payload| payload['kind'] == 'scheduler_stall_frame' }).to be(true)

    watchdog.stop
    heartbeat.resume if heartbeat.alive?
    recorder.close
  end

  it 'closes an in-progress stall once with resumed false' do
    watchdog, recorder, _operations, io, set_now = build_runtime(watchdog_values: { max_frames: 0 })
    set_now.call(1)
    heartbeat = attach_heartbeat(watchdog)
    watchdog.poll(now_ns: 100_000_002)
    set_now.call(150_000_000)

    2.times { watchdog.stop }
    heartbeat.resume if heartbeat.alive?
    recorder.close

    completions = event_payloads(io).select { |payload| payload['kind'] == 'scheduler_stall_completed' }
    expect(completions.size).to eq(1)
    expect(completions.first.dig('measurements', 'resumed')).to be(false)
  end

  it 'marks unsupported scheduler setup explicitly' do
    watchdog, recorder, _operations, io, = build_runtime

    watchdog.scheduler_unsupported(thread: Thread.current)
    watchdog.stop
    recorder.close

    expect(watchdog.state).to eq(:unsupported)
    expect(event_payloads(io).map { |payload| payload['kind'] }).to include('watchdog_unsupported')
  end

  it 'honors fail-open and fail-closed watchdog errors' do
    open_watchdog, open_recorder, _operations, _io, set_now = build_runtime
    set_now.call(100)
    attach_heartbeat(open_watchdog)
    expect(open_watchdog.poll(now_ns: 99)).to eq(:unsupported)
    expect(open_watchdog.state).to eq(:unsupported)
    open_watchdog.stop
    expect(open_recorder.close.internal_errors).to eq(1)

    closed_watchdog, closed_recorder, _operations, _io, closed_set_now = build_runtime(fail_open: false)
    closed_set_now.call(100)
    attach_heartbeat(closed_watchdog)
    expect { closed_watchdog.poll(now_ns: 99) }
      .to raise_error(FiberAudit::RuntimeSafetyError, /moved backwards/)
    closed_watchdog.stop
    closed_recorder.close
  end

  context 'with scheduler stall operation overlap events' do
    it 'emits overlap events for active operations on stalled scheduler thread' do
      watchdog, recorder, operations, io, set_now = build_runtime(
        watchdog_values: { heartbeat_interval_ms: 25, stall_threshold_ms: 100, max_frames: 0 }
      )
      set_now.call(10)
      heartbeat = attach_heartbeat(watchdog)

      snapshot = FiberAudit::Runtime::SchedulerSnapshot.new(
        scheduler_present: true,
        fiber_blocking: false,
        scheduler_io_select_supported: true,
        scheduler_process_wait_supported: false,
        scheduler_address_resolve_supported: nil
      )

      operations.register(
        operation: 'Mutex#lock',
        location: FiberAudit::Runtime::Location.new(path: 'app/task.rb', line: 1),
        execution_context: :job,
        monotonic_ns: 20,
        thread: Thread.current,
        fiber: Fiber.current,
        scheduler_snapshot: snapshot
      )

      operations.register(
        operation: 'IO.select',
        location: FiberAudit::Runtime::Location.new(path: 'app/io.rb', line: 5),
        execution_context: :request,
        monotonic_ns: 30,
        thread: Thread.current,
        fiber: Fiber.current,
        scheduler_snapshot: snapshot
      )

      watchdog.poll(now_ns: 100_000_011)
      payloads = event_payloads(io)

      overlap_events = payloads.select { |payload| payload['kind'] == 'scheduler_stall_operation_overlap' }

      expect(overlap_events.size).to eq(2)

      first_overlap = overlap_events.find { |e| e['operation'] == 'Mutex#lock' }
      expect(first_overlap).not_to be_nil
      expect(first_overlap.dig('measurements', 'stall_sequence')).to eq(1)
      expect(first_overlap.dig('measurements', 'operation_sequence')).to eq(1)
      expect(first_overlap.dig('measurements', 'operation_started_monotonic_ns')).to eq(20)
      expect(first_overlap.dig('measurements', 'scheduler_present')).to be(true)
      expect(first_overlap.dig('measurements', 'fiber_blocking')).to be(false)
      expect(first_overlap.dig('measurements', 'scheduler_io_select_supported')).to be(true)
      expect(first_overlap.dig('measurements', 'overlap_truncated')).to be(false)
      expect(first_overlap.dig('measurements', 'overlap_total_count')).to eq(2)

      second_overlap = overlap_events.find { |e| e['operation'] == 'IO.select' }
      expect(second_overlap).not_to be_nil
      expect(second_overlap.dig('measurements', 'operation_sequence')).to eq(2)
      expect(second_overlap.dig('measurements', 'scheduler_present')).to be(true)

      watchdog.stop
      heartbeat.resume if heartbeat.alive?
      recorder.close
    end

    it 'bounds overlap events to MAX_OVERLAP_EVENTS and marks truncation' do
      watchdog, recorder, operations, io, set_now = build_runtime(
        watchdog_values: { heartbeat_interval_ms: 25, stall_threshold_ms: 100, max_frames: 0 }
      )
      set_now.call(10)
      heartbeat = attach_heartbeat(watchdog)

      # Register more than MAX_OVERLAP_EVENTS (10) operations
      15.times do |i|
        operations.register(
          operation: 'Mutex#lock',
          location: FiberAudit::Runtime::Location.new(path: 'app/task.rb', line: i + 1),
          execution_context: :job,
          monotonic_ns: 20 + i,
          thread: Thread.current,
          fiber: Fiber.current
        )
      end

      watchdog.poll(now_ns: 100_000_011)
      payloads = event_payloads(io)

      overlap_events = payloads.select { |payload| payload['kind'] == 'scheduler_stall_operation_overlap' }

      # Should be bounded to 10 events
      expect(overlap_events.size).to eq(10)

      # All should be marked as truncated with total count of 15
      overlap_events.each do |event|
        expect(event.dig('measurements', 'overlap_truncated')).to be(true)
        expect(event.dig('measurements', 'overlap_total_count')).to eq(15)
      end

      watchdog.stop
      heartbeat.resume if heartbeat.alive?
      recorder.close
    end

    it 'preserves aggregate stall events alongside overlap events' do
      watchdog, recorder, operations, io, set_now = build_runtime(
        watchdog_values: { heartbeat_interval_ms: 25, stall_threshold_ms: 100, max_frames: 0 }
      )
      set_now.call(10)
      heartbeat = attach_heartbeat(watchdog)

      operations.register(
        operation: 'Mutex#lock',
        location: FiberAudit::Runtime::Location.new(path: 'app/task.rb', line: 1),
        execution_context: :job,
        monotonic_ns: 20,
        thread: Thread.current,
        fiber: Fiber.current
      )

      watchdog.poll(now_ns: 100_000_011)
      payloads = event_payloads(io)

      # Should have both aggregate and overlap events
      stall_started = payloads.select { |p| p['kind'] == 'scheduler_stall_started' }
      stall_completed = payloads.select { |p| p['kind'] == 'scheduler_stall_completed' }
      overlap_events = payloads.select { |p| p['kind'] == 'scheduler_stall_operation_overlap' }

      expect(stall_started.size).to eq(1)
      expect(stall_completed.size).to eq(0) # Not completed yet
      expect(overlap_events.size).to eq(1)

      # Aggregate event should still have active_operation_count
      expect(stall_started.first.dig('measurements', 'active_operation_count')).to eq(1)
      expect(stall_started.first.dig('measurements', 'active_operation_first_sequence')).to eq(1)

      watchdog.stop
      heartbeat.resume if heartbeat.alive?
      recorder.close
    end

    it 'omits overlap events when no active operations on stalled thread' do
      watchdog, recorder, _operations, io, set_now = build_runtime(
        watchdog_values: { heartbeat_interval_ms: 25, stall_threshold_ms: 100, max_frames: 0 }
      )
      set_now.call(10)
      heartbeat = attach_heartbeat(watchdog)

      # No operations registered
      watchdog.poll(now_ns: 100_000_011)
      payloads = event_payloads(io)

      overlap_events = payloads.select { |payload| payload['kind'] == 'scheduler_stall_operation_overlap' }
      expect(overlap_events).to be_empty

      watchdog.stop
      heartbeat.resume if heartbeat.alive?
      recorder.close
    end

    it 'includes scheduler snapshot measurements in overlap events' do
      watchdog, recorder, operations, io, set_now = build_runtime(
        watchdog_values: { heartbeat_interval_ms: 25, stall_threshold_ms: 100, max_frames: 0 }
      )
      set_now.call(10)
      heartbeat = attach_heartbeat(watchdog)

      snapshot = FiberAudit::Runtime::SchedulerSnapshot.new(
        scheduler_present: true,
        fiber_blocking: true,
        scheduler_io_select_supported: false,
        scheduler_process_wait_supported: true,
        scheduler_address_resolve_supported: false
      )

      operations.register(
        operation: 'Thread.join',
        location: FiberAudit::Runtime::Location.new(path: 'app/thread.rb', line: 10),
        execution_context: :job,
        monotonic_ns: 50,
        thread: Thread.current,
        fiber: Fiber.current,
        scheduler_snapshot: snapshot
      )

      watchdog.poll(now_ns: 100_000_011)
      payloads = event_payloads(io)

      overlap_event = payloads.find { |p| p['kind'] == 'scheduler_stall_operation_overlap' }
      expect(overlap_event).not_to be_nil

      measurements = overlap_event['measurements']
      expect(measurements['scheduler_present']).to be(true)
      expect(measurements['fiber_blocking']).to be(true)
      expect(measurements['scheduler_io_select_supported']).to be(false)
      expect(measurements['scheduler_process_wait_supported']).to be(true)
      expect(measurements['scheduler_address_resolve_supported']).to be(false)

      watchdog.stop
      heartbeat.resume if heartbeat.alive?
      recorder.close
    end

    it 'handles operations without scheduler snapshot gracefully' do
      watchdog, recorder, operations, io, set_now = build_runtime(
        watchdog_values: { heartbeat_interval_ms: 25, stall_threshold_ms: 100, max_frames: 0 }
      )
      set_now.call(10)
      heartbeat = attach_heartbeat(watchdog)

      # Register operation without scheduler snapshot (backward compatibility)
      operations.register(
        operation: 'Mutex#lock',
        location: FiberAudit::Runtime::Location.new(path: 'app/task.rb', line: 1),
        execution_context: :job,
        monotonic_ns: 20,
        thread: Thread.current,
        fiber: Fiber.current
      )

      watchdog.poll(now_ns: 100_000_011)
      payloads = event_payloads(io)

      overlap_event = payloads.find { |p| p['kind'] == 'scheduler_stall_operation_overlap' }
      expect(overlap_event).not_to be_nil

      measurements = overlap_event['measurements']
      # Should have overlap-specific measurements but no scheduler snapshot measurements
      expect(measurements).to include('stall_sequence', 'operation_sequence', 'operation_started_monotonic_ns')
      expect(measurements).not_to include('scheduler_present')

      watchdog.stop
      heartbeat.resume if heartbeat.alive?
      recorder.close
    end
  end
end
