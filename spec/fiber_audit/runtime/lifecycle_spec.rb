# frozen_string_literal: true

require 'json'
require 'stringio'
require 'tmpdir'
require 'fiber_audit/runtime/lifecycle'

RSpec.describe FiberAudit::Runtime::Lifecycle do
  let(:launch_id) { '123e4567-e89b-42d3-a456-426614174000' }
  let(:session_ids) do
    %w[
      aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
      bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
    ]
  end

  def build_settings(root:, output:, fail_open: true)
    FiberAudit::Runtime::Environment.build(
      policy: FiberAudit::Runtime::Policy.new(sampling_rate: 1.0, fail_open: fail_open),
      output_directory: output,
      project_root: root,
      launch_id: launch_id
    )
  end

  def build_clock
    monotonic = 100
    FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12) },
      monotonic: -> { monotonic += 1 }
    )
  end

  def memory_writer_factory(streams)
    lambda do |path:, max_record_bytes:|
      io = StringIO.new
      streams[path] = io
      FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: max_record_bytes)
    end
  end

  def with_runtime
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      yield root, output
    end
  end

  it 'owns one start/end-only process session with a collision-resistant filename' do
    with_runtime do |root, output|
      streams = {}
      ids = session_ids.dup
      lifecycle = described_class.start(
        settings: build_settings(root: root, output: output),
        clock: build_clock,
        session_id_source: -> { ids.shift },
        pid_source: -> { 4321 },
        writer_factory: memory_writer_factory(streams)
      )

      expect(lifecycle).to be_active
      expect(File.basename(lifecycle.output_path)).to eq(
        "fiber-audit-runtime-#{launch_id}-4321-#{session_ids.first}.jsonl"
      )
      first = lifecycle.shutdown
      second = lifecycle.shutdown(exception: RuntimeError.new('ignored after close'))
      records = streams.fetch(lifecycle.output_path).string.lines.map { |line| JSON.parse(line) }

      expect(second).to equal(first)
      expect(records.map { |record| record['record_type'] }).to eq(%w[session_start session_end])
      expect(records.map { |record| record['sequence'] }).to eq([0, 1])
      expect(records.last.dig('payload', 'status')).to eq('completed')
    end
  end

  it 'owns explicit watchdog state and a process-local active-operation registry' do
    with_runtime do |root, output|
      streams = {}
      lifecycle = described_class.start(
        settings: build_settings(root: root, output: output),
        watchdog_policy: FiberAudit::Runtime::WatchdogPolicy.new,
        clock: build_clock,
        session_id_source: -> { session_ids.first },
        pid_source: -> { 4500 },
        writer_factory: memory_writer_factory(streams)
      )

      expect(lifecycle.watchdog.state).to eq(:absent)
      expect(lifecycle.active_operations).to be_a(FiberAudit::Runtime::ActiveOperations)
      lifecycle.shutdown
      records = streams.fetch(lifecycle.output_path).string.lines.map { |line| JSON.parse(line) }

      expect(records.map { |record| record['record_type'] }).to eq(%w[session_start event session_end])
      expect(records.fetch(1).dig('payload', 'kind')).to eq('watchdog_absent')
    end
  end

  it 'maps orderly SystemExit to completed and unhandled failures to aborted' do
    with_runtime do |root, output|
      [
        [SystemExit.new(7), 'completed'],
        [RuntimeError.new('secret exception'), 'aborted'],
        [Interrupt.new('interrupted'), 'aborted']
      ].each_with_index do |(exception, expected), index|
        streams = {}
        lifecycle = described_class.start(
          settings: build_settings(root: root, output: output),
          clock: build_clock,
          session_id_source: -> { session_ids.fetch(index % session_ids.size) },
          pid_source: -> { 5000 + index },
          writer_factory: memory_writer_factory(streams)
        )
        lifecycle.shutdown(exception: exception)
        payload = JSON.parse(streams.fetch(lifecycle.output_path).string.lines.last).fetch('payload')

        expect(payload.fetch('status')).to eq(expected)
        expect(streams.fetch(lifecycle.output_path).string).not_to include('secret exception')
      end
    end
  end

  it 'abandons the inherited writer and starts a distinct session after a PID change' do
    with_runtime do |root, output|
      streams = {}
      ids = session_ids.dup
      pid = 6000
      lifecycle = described_class.start(
        settings: build_settings(root: root, output: output),
        clock: build_clock,
        session_id_source: -> { ids.shift },
        pid_source: -> { pid },
        writer_factory: memory_writer_factory(streams)
      )
      inherited_path = lifecycle.output_path
      pid = 6001

      lifecycle.ensure_current_process!
      child_path = lifecycle.output_path
      lifecycle.shutdown

      expect(child_path).not_to eq(inherited_path)
      expect(streams.fetch(inherited_path).string.lines.size).to eq(1)
      expect(JSON.parse(streams.fetch(inherited_path).string)['record_type']).to eq('session_start')
      child_records = streams.fetch(child_path).string.lines.map { |line| JSON.parse(line) }
      expect(child_records.map { |record| record['record_type'] }).to eq(%w[session_start session_end])
      expect(child_records.first.fetch('session_id')).not_to eq(
        JSON.parse(streams.fetch(inherited_path).string).fetch('session_id')
      )
    end
  end

  it 'rebuilds watchdog and operation state without locking inherited objects after a PID change' do
    with_runtime do |root, output|
      streams = {}
      ids = session_ids.dup
      pid = 6500
      lifecycle = described_class.start(
        settings: build_settings(root: root, output: output),
        watchdog_policy: FiberAudit::Runtime::WatchdogPolicy.new,
        clock: build_clock,
        session_id_source: -> { ids.shift },
        pid_source: -> { pid },
        writer_factory: memory_writer_factory(streams)
      )
      parent_watchdog = lifecycle.watchdog
      parent_operations = lifecycle.active_operations
      pid = 6501

      lifecycle.ensure_current_process!

      expect(lifecycle.watchdog).not_to equal(parent_watchdog)
      expect(lifecycle.active_operations).not_to equal(parent_operations)
      expect(lifecycle.owner_pid).to eq(6501)
      lifecycle.shutdown
    end
  end

  it 'disables startup failures in fail-open mode and propagates them in fail-closed mode' do
    with_runtime do |root, output|
      error = IOError.new('disk unavailable')
      failing_factory = ->(**) { raise error }

      open_lifecycle = described_class.start(
        settings: build_settings(root: root, output: output),
        clock: build_clock,
        session_id_source: -> { session_ids.first },
        pid_source: -> { 7000 },
        writer_factory: failing_factory
      )
      expect(open_lifecycle).to be_disabled
      expect(open_lifecycle.shutdown).to be_nil

      expect do
        described_class.start(
          settings: build_settings(root: root, output: output, fail_open: false),
          clock: build_clock,
          session_id_source: -> { session_ids.first },
          pid_source: -> { 7001 },
          writer_factory: failing_factory
        )
      end.to raise_error(error)
    end
  end

  it 'degrades fail-open watchdog startup and closes fail-closed startup sessions' do
    with_runtime do |root, output|
      error = IOError.new('watchdog clock failed')
      [true, false].each_with_index do |fail_open, index|
        streams = {}
        monotonic_calls = 0
        clock = FiberAudit::Runtime::Clock.new(
          wall: -> { Time.utc(2026, 8, 2, 12) },
          monotonic: lambda do
            monotonic_calls += 1
            raise error if monotonic_calls > 1

            100
          end
        )
        arguments = {
          settings: build_settings(root: root, output: output, fail_open: fail_open),
          watchdog_policy: FiberAudit::Runtime::WatchdogPolicy.new,
          clock: clock,
          session_id_source: -> { session_ids.fetch(index) },
          pid_source: -> { 9000 + index },
          writer_factory: memory_writer_factory(streams)
        }

        if fail_open
          lifecycle = described_class.start(**arguments)
          expect(lifecycle.watchdog).to be_nil
          expect(lifecycle.shutdown.status).to eq(:degraded)
        else
          expect { described_class.start(**arguments) }.to raise_error(error)
        end

        records = streams.values.first.string.lines.map { |line| JSON.parse(line) }
        expect(records.first['record_type']).to eq('session_start')
        expect(records.last['record_type']).to eq('session_end') unless fail_open
      end
    end
  end

  it 'preserves fail-open and fail-closed behavior for end-record failures' do
    with_runtime do |root, output|
      error = IOError.new('end write failed')
      factory = lambda do |path:, max_record_bytes:|
        _path = path
        io = fail_after_writes_io_class.new(successful_writes: 1, error: error)
        FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: max_record_bytes)
      end

      open_lifecycle = described_class.start(
        settings: build_settings(root: root, output: output),
        clock: build_clock,
        session_id_source: -> { session_ids.first },
        pid_source: -> { 8000 },
        writer_factory: factory
      )
      expect(open_lifecycle.shutdown.status).to eq(:degraded)

      closed_lifecycle = described_class.start(
        settings: build_settings(root: root, output: output, fail_open: false),
        clock: build_clock,
        session_id_source: -> { session_ids.last },
        pid_source: -> { 8001 },
        writer_factory: factory
      )
      expect { closed_lifecycle.shutdown }.to raise_error(error)
    end
  end

  let(:fail_after_writes_io_class) do
    Class.new do
      def initialize(successful_writes:, error:)
        @successful_writes = successful_writes
        @error = error
        @writes = 0
      end

      def write(value)
        raise @error if @writes >= @successful_writes

        @writes += 1
        value.bytesize
      end

      def flush; end
    end
  end
end
