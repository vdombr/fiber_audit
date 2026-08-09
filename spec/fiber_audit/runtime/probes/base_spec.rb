# frozen_string_literal: true

require 'json'
require 'stringio'
require 'fiber_audit/runtime/probes/base'

RSpec.describe FiberAudit::Runtime::Probes::Base do
  let(:session_id) { '123e4567-e89b-42d3-a456-426614174000' }

  def build_base(fail_open: true, sampling_rate: 1.0, probe_times: [100, 150])
    policy = FiberAudit::Runtime::Policy.new(
      sampling_rate: sampling_rate,
      fail_open: fail_open,
      max_events_per_second: 100,
      max_events_per_session: 1_000
    )
    io = StringIO.new
    session = FiberAudit::Runtime::Session.new(
      id: session_id,
      started_at: Time.utc(2026, 8, 2, 12),
      started_monotonic_ns: 1,
      policy: policy
    )
    recorder_clock = FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12) },
      monotonic: -> { 1_000 }
    )
    writer = FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: policy.max_record_bytes)
    recorder = FiberAudit::Runtime::Recorder.start(
      session: session,
      writer: writer,
      clock: recorder_clock,
      random: -> { 0.5 }
    )
    times = probe_times.dup
    probe_clock = FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12, 0, 1) },
      monotonic: lambda do
        value = times.shift
        raise value if value.is_a?(Exception)

        value || probe_times.last
      end
    )
    operations = FiberAudit::Runtime::ActiveOperations.new
    base = described_class.new(
      recorder: recorder,
      clock: probe_clock,
      redactor: FiberAudit::Runtime::Redactor.new(root: Dir.pwd, policy: policy),
      active_operations: operations
    )
    [base, recorder, operations, io]
  end

  def events(io)
    io.string.lines
      .map { |line| JSON.parse(line) }
      .select { |record| record['record_type'] == 'event' }
  end

  it 'preserves return identity and emits bounded completed evidence' do
    base, recorder, operations, io = build_base
    result = Object.new

    returned = base.observe(operation: 'Mutex#lock', measurements: { contention_observed: false }) { result }
    recorder.close
    event = events(io).first

    expect(returned).to equal(result)
    expect(operations.size).to eq(0)
    expect(event.dig('payload', 'kind')).to eq('operation_completed')
    expect(event.dig('payload', 'operation')).to eq('Mutex#lock')
    expect(event.dig('payload', 'duration_ns')).to eq(50)
    expect(event.dig('payload', 'location', 'path')).to eq('spec/fiber_audit/runtime/probes/base_spec.rb')
    expect(event.dig('payload', 'measurements')).to include(
      'contention_observed' => false,
      'operation_sequence' => 1
    )
  end

  it 're-raises the exact application exception and records no exception data' do
    base, recorder, _operations, io = build_base
    error = Class.new(StandardError).new('credential-secret')

    expect do
      base.observe(operation: 'Thread.join') { raise error }
    end.to(raise_error { |raised| expect(raised).to equal(error) })
    recorder.close

    expect(events(io).first.dig('payload', 'kind')).to eq('operation_aborted')
    expect(io.string).not_to include('credential-secret')
  end

  it 'does not swallow non-StandardError application failures' do
    base, recorder, = build_base
    interrupt = Interrupt.new('application interrupt')

    expect do
      base.observe(operation: 'IO.select') { raise interrupt }
    end.to(raise_error { |raised| expect(raised).to equal(interrupt) })
    recorder.close
  end

  it 'keeps nested application operations observable while guarding internals' do
    base, recorder, _operations, io = build_base(probe_times: [10, 20, 30, 40])

    base.observe(operation: 'Mutex#synchronize') do
      base.observe(operation: 'Thread.value') { :value }
    end
    recorder.close

    expect(events(io).map { |event| event.dig('payload', 'operation') })
      .to eq(%w[Thread.value Mutex#synchronize])
  end

  it 'registers the operation for watchdog overlap only while application code runs' do
    base, recorder, operations, = build_base
    snapshot = nil

    base.observe(operation: 'ConditionVariable#wait') do
      snapshot = operations.snapshot
      :done
    end

    expect(snapshot.map(&:operation)).to eq(['ConditionVariable#wait'])
    expect(snapshot.first.sequence).to eq(1)
    expect(operations.size).to eq(0)
    recorder.close
  end

  it 'lets recorder sampling skip event construction without changing the result' do
    base, recorder, _operations, io = build_base(sampling_rate: 0.0)

    expect(base.observe(operation: 'Mutex#lock') { :result }).to eq(:result)
    summary = recorder.close

    expect(summary.sampled_out).to eq(1)
    expect(events(io)).to be_empty
  end

  it 'fails open before the operation and invokes application code exactly once' do
    error = IOError.new('clock unavailable')
    base, recorder, _operations, io = build_base(probe_times: [error])
    calls = 0

    result = base.observe(operation: 'Mutex#lock') do
      calls += 1
      :result
    end

    expect(result).to eq(:result)
    expect(calls).to eq(1)
    expect(recorder.close.internal_errors).to eq(1)
    expect(io.string).not_to include(error.message)
  end

  it 'raises a post-return instrumentation failure only in fail-closed mode' do
    error = IOError.new('clock unavailable')
    base, recorder, = build_base(fail_open: false, probe_times: [10, error])
    calls = 0

    expect do
      base.observe(operation: 'Mutex#lock') do
        calls += 1
        :result
      end
    end.to(raise_error { |raised| expect(raised).to equal(error) })
    expect(calls).to eq(1)
    recorder.close
  end

  it 'prioritizes an application exception over fail-closed finalization errors' do
    instrumentation_error = IOError.new('clock unavailable')
    application_error = Class.new(StandardError).new('application failure')
    base, recorder, = build_base(fail_open: false, probe_times: [10, instrumentation_error])

    expect do
      base.observe(operation: 'Mutex#lock') { raise application_error }
    end.to(raise_error { |raised| expect(raised).to equal(application_error) })
    recorder.close
  end

  it 'stops emitting after deactivation while cleaning an active handle' do
    base, recorder, operations, io = build_base

    result = base.observe(operation: 'Thread.join') do
      expect(operations.size).to eq(1)
      base.deactivate
      :result
    end
    recorder.close

    expect(result).to eq(:result)
    expect(operations.size).to eq(0)
    expect(events(io)).to be_empty
  end
end
