# frozen_string_literal: true

require 'json'
require 'stringio'
require 'fiber_audit/runtime/recorder'

RSpec.describe FiberAudit::Runtime::Recorder do
  let(:session_id) { '123e4567-e89b-42d3-a456-426614174000' }
  let(:started_at) { Time.utc(2026, 8, 2, 12) }
  let(:fail_after_writes_io_class) do
    Class.new do
      attr_reader :string

      def initialize(successful_writes:, error: IOError.new('disk failed'))
        @successful_writes = successful_writes
        @error = error
        @writes = 0
        @string = +''
      end

      def write(value)
        raise @error if @writes >= @successful_writes

        @writes += 1
        @string << value
        value.bytesize
      end

      def flush; end
    end
  end

  def build_event(path: 'app/jobs/task.rb', monotonic_ns: 200)
    FiberAudit::Runtime::Event.new(
      kind: :operation_completed,
      source: :instrumentation,
      occurred_at: Time.utc(2026, 8, 2, 12, 0, 1),
      monotonic_ns: monotonic_ns,
      duration_ns: 50,
      operation: 'Mutex#lock',
      location: FiberAudit::Runtime::Location.new(path: path, line: 8, column: 2),
      execution_context: :job,
      thread_id: 4,
      fiber_id: 7,
      measurements: { threshold_ns: 25 }
    )
  end

  def build_recorder(policy: FiberAudit::Runtime::Policy.new(sampling_rate: 1.0),
                     io: StringIO.new, random: -> { 0.0 }, monotonic: nil)
    tick = 100
    monotonic ||= lambda {
      tick += 1
    }
    session = FiberAudit::Runtime::Session.new(
      id: session_id,
      started_at: started_at,
      started_monotonic_ns: 100,
      policy: policy,
      tool_version: '0.2.0',
      ruby_version: '3.4.9'
    )
    writer = FiberAudit::Runtime::JSONL::Writer.new(
      io: io,
      max_record_bytes: policy.max_record_bytes
    )
    clock = FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12, 0, 2) },
      monotonic: monotonic
    )
    [described_class.start(session: session, writer: writer, clock: clock, random: random), io]
  end

  it 'writes one ordered start, event, and end session' do
    recorder, io = build_recorder

    expect(recorder.record { build_event }).to eq(:emitted)
    summary = recorder.close
    records = io.string.lines.map { |line| JSON.parse(line) }

    expect(records.map { |record| record['record_type'] }).to eq(%w[session_start event session_end])
    expect(records.map { |record| record['sequence'] }).to eq([0, 1, 2])
    expect(summary.status).to eq(:completed)
    expect(summary.events_observed).to eq(1)
    expect(summary.events_emitted).to eq(1)
    expect(records.last['payload']['events_emitted']).to eq(1)
  end

  it 'fails open without appending when startup receives a nonempty writer' do
    policy = FiberAudit::Runtime::Policy.new(sampling_rate: 1.0)
    io = StringIO.new
    writer = FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: policy.max_record_bytes)
    session = FiberAudit::Runtime::Session.new(
      id: session_id,
      started_at: started_at,
      started_monotonic_ns: 100,
      policy: policy
    )
    writer.write(FiberAudit::Runtime::JSONL::Schema.start_record(session))
    original = io.string.dup

    recorder = described_class.start(session: session, writer: writer)

    expect(recorder).to be_disabled
    expect(recorder.record { build_event }).to eq(:inactive)
    expect(recorder.close.status).to eq(:degraded)
    expect(io.string).to eq(original)
  end

  it 'samples before invoking the event factory' do
    policy = FiberAudit::Runtime::Policy.new(sampling_rate: 0.0)
    recorder, = build_recorder(policy: policy)
    called = false

    result = recorder.record do
      called = true
      build_event
    end

    expect(result).to eq(:sampled_out)
    expect(called).to be(false)
    expect(recorder.close.sampled_out).to eq(1)
  end

  it 'applies the session limit before the rate limit' do
    policy = FiberAudit::Runtime::Policy.new(
      sampling_rate: 1.0,
      max_events_per_session: 1,
      max_events_per_second: 1
    )
    recorder, = build_recorder(policy: policy)

    expect(recorder.record { build_event }).to eq(:emitted)
    expect(recorder.record { build_event }).to eq(:session_event_limited)
    summary = recorder.close
    expect(summary.session_event_limited).to eq(1)
    expect(summary.rate_limited).to eq(0)
  end

  it 'disables safely when the monotonic clock moves backwards' do
    times = [200, 199, 300]
    recorder, = build_recorder(monotonic: -> { times.shift })

    expect(recorder.record { build_event }).to eq(:emitted)
    expect(recorder.record { build_event }).to eq(:internal_error)
    expect(recorder).to be_disabled
    summary = recorder.close
    expect(summary.status).to eq(:degraded)
    expect(summary.internal_errors).to eq(1)
  end

  it 'rate limits within a fixed window and admits the boundary' do
    times = [100, 101, 1_000_000_100, 1_000_000_101]
    policy = FiberAudit::Runtime::Policy.new(sampling_rate: 1.0, max_events_per_second: 1)
    recorder, = build_recorder(policy: policy, monotonic: -> { times.shift })

    expect(recorder.record { build_event }).to eq(:emitted)
    expect(recorder.record { build_event }).to eq(:rate_limited)
    expect(recorder.record { build_event }).to eq(:emitted)
    expect(recorder.close.rate_limited).to eq(1)
  end

  it 'drops oversized events before writing any event bytes' do
    policy = FiberAudit::Runtime::Policy.new(
      sampling_rate: 1.0,
      max_record_bytes: 1_024,
      max_session_bytes: 4_096
    )
    recorder, io = build_recorder(policy: policy)

    expect(recorder.record { build_event(path: "#{'a' * 900}.rb") }).to eq(:oversize)
    summary = recorder.close
    expect(summary.oversize).to eq(1)
    expect(io.string.lines.map { |line| JSON.parse(line)['record_type'] }).to eq(%w[session_start session_end])
  end

  it 'reserves room for the end record when the session byte limit is reached' do
    policy = FiberAudit::Runtime::Policy.new(
      sampling_rate: 1.0,
      max_events_per_second: 100,
      max_events_per_session: 100,
      max_record_bytes: 1_024,
      max_session_bytes: 4_096
    )
    recorder, io = build_recorder(policy: policy)
    results = 20.times.map { recorder.record { build_event } }
    summary = recorder.close

    expect(results).to include(:session_byte_limited)
    expect(summary.session_byte_limited).to be_positive
    expect(io.string.bytesize).to be <= policy.max_session_bytes
    expect(JSON.parse(io.string.lines.last)['record_type']).to eq('session_end')
  end

  it 'disables recording after an IO failure in fail-open mode' do
    io = fail_after_writes_io_class.new(successful_writes: 1)
    recorder, = build_recorder(io: io)

    expect(recorder.record { build_event }).to eq(:internal_error)
    expect(recorder).to be_disabled
    expect(recorder.record { build_event }).to eq(:inactive)
    summary = recorder.close
    expect(summary.status).to eq(:degraded)
    expect(summary.internal_errors).to eq(1)
  end

  it 're-raises the same IO failure in fail-closed mode' do
    policy = FiberAudit::Runtime::Policy.new(sampling_rate: 1.0, fail_open: false)
    io = fail_after_writes_io_class.new(successful_writes: 1)
    recorder, = build_recorder(policy: policy, io: io)

    expect { recorder.record { build_event } }.to raise_error(IOError, 'disk failed')
    expect(recorder).to be_disabled
    expect(recorder.close.status).to eq(:degraded)
  end

  it 'propagates event factory exceptions and remains usable' do
    recorder, = build_recorder
    error = Class.new(StandardError).new('application error')

    expect { recorder.record { raise error } }.to raise_error(error)
    expect(recorder).to be_active
    expect(recorder.record { build_event }).to eq(:emitted)
    expect(recorder.close.events_observed).to eq(2)
  end

  it 'does not swallow non-StandardError factory or writer failures' do
    recorder, = build_recorder
    exit_error = SystemExit.new(7)
    expect { recorder.record { raise exit_error } }.to raise_error(exit_error)
    expect(recorder).to be_active
    recorder.close

    interrupt = Interrupt.new('interrupted')
    io = fail_after_writes_io_class.new(successful_writes: 1, error: interrupt)
    interrupted_recorder, = build_recorder(io: io)
    expect { interrupted_recorder.record { build_event } }.to raise_error(interrupt)
    expect(interrupted_recorder).to be_disabled
    expect(interrupted_recorder.close.status).to eq(:degraded)
  end

  it 'assigns contiguous sequences to concurrently emitted events' do
    recorder, io = build_recorder
    threads = 20.times.map do
      Thread.new { recorder.record { build_event } }
    end
    expect(threads.map(&:value)).to all(eq(:emitted))
    recorder.close

    records = io.string.lines.map { |line| JSON.parse(line) }
    expect(records.map { |record| record['sequence'] }).to eq((0..21).to_a)
  end

  it 'writes no event after close wins a race with an in-flight factory' do
    recorder, io = build_recorder
    started = Queue.new
    release = Queue.new
    thread = Thread.new do
      recorder.record do
        started << true
        release.pop
        build_event
      end
    end
    started.pop

    summary = recorder.close
    release << true

    expect(thread.value).to eq(:inactive)
    expect(summary.internal_errors).to eq(1)
    expect(io.string.lines.map { |line| JSON.parse(line)['record_type'] }).to eq(%w[session_start session_end])
  end

  it 'preserves an in-flight factory exception after close accounts for it' do
    recorder, io = build_recorder
    started = Queue.new
    release = Queue.new
    error = Class.new(StandardError).new('factory failed')
    thread = Thread.new do
      recorder.record do
        started << true
        release.pop
        raise error
      end
    end
    thread.report_on_exception = false
    started.pop

    summary = recorder.close
    release << true

    expect { thread.value }.to raise_error(error)
    expect(summary.internal_errors).to eq(1)
    expect(io.string.lines.map { |line| JSON.parse(line)['record_type'] }).to eq(%w[session_start session_end])
  end

  it 'records a close-time clock failure as a degraded end record' do
    clock_error = IOError.new('clock failed')
    recorder, io = build_recorder(monotonic: -> { raise clock_error })

    summary = recorder.close
    end_payload = JSON.parse(io.string.lines.last).fetch('payload')

    expect(summary.status).to eq(:degraded)
    expect(summary.internal_errors).to eq(1)
    expect(summary.ended_at).to eq(started_at)
    expect(summary.ended_monotonic_ns).to eq(100)
    expect(end_payload['status']).to eq('degraded')
    expect(end_payload['internal_errors']).to eq(1)
  end

  it 'closes idempotently and rejects later observations' do
    recorder, io = build_recorder
    first = recorder.close(status: :aborted)
    second = recorder.close

    expect(second).to equal(first)
    expect(first.status).to eq(:aborted)
    expect(recorder).to be_closed
    expect(recorder.record { build_event }).to eq(:inactive)
    expect(io.string.lines.size).to eq(2)
  end
end
