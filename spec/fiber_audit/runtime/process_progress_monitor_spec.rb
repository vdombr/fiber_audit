# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'stringio'
require 'tmpdir'
require 'fiber_audit/runtime/process_progress_monitor'

RSpec.describe FiberAudit::Runtime::ProcessProgressMonitor do
  let(:session_id) { '123e4567-e89b-42d3-a456-426614174000' }
  let(:policy) do
    FiberAudit::Runtime::ProcessProgressPolicy.new(
      enabled: true, heartbeat_interval_ms: 10, stall_threshold_ms: 50,
      max_processes: 2, max_frames_per_poll: 8, max_buffer_bytes: 320
    )
  end

  # RSpec-local nonblocking reader fixture.
  # rubocop:disable Lint/ConstantDefinitionInBlock
  class Reader
    def read_nonblock(*) = :wait_readable
    def close = @closed = true
    def closed? = @closed == true
  end
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def build_monitor(runtime_policy: FiberAudit::Runtime::Policy.new(sampling_rate: 1.0))
    root = Dir.mktmpdir
    output = File.join(root, 'runtime')
    Dir.mkdir(output)
    settings = FiberAudit::Runtime::Environment.build(
      policy: runtime_policy, output_directory: output, project_root: root, launch_id: session_id
    )
    io = StringIO.new
    clock = FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12) }, monotonic: -> { 100 }
    )
    writer_factory = lambda { |max_record_bytes:, **|
      FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: max_record_bytes)
    }
    monitor = described_class.new(
      policy: policy, settings: settings, reader: Reader.new, clock: clock,
      session_id_source: -> { session_id }, pid_source: -> { 500 },
      writer_factory: writer_factory,
      thread_factory: ->(&) { Thread.new { nil } }
    )
    [monitor, io, root]
  end

  def frame(pid:, generation:, sequence:, monotonic_ns:)
    FiberAudit::Runtime::ProcessProgressProtocol.encode(
      pid: pid, generation: generation, sequence: sequence, monotonic_ns: monotonic_ns
    )
  end

  def events(io)
    io.string.lines.map { |line| JSON.parse(line) }
                   .filter_map { |record| record['payload'] if record['record_type'] == 'event' }
  end

  it 'writes a separate parent-monitor session with bounded scalar evidence' do
    monitor, io, root = build_monitor
    monitor.stop
    records = io.string.lines.map { |line| JSON.parse(line) }

    expect(records.map { |record| record['schema_version'] }.uniq).to eq(['1.1'])
    expect(records.first.dig('payload', 'process_role')).to eq('parent_monitor')
    expect(monitor.output_path).to include('fiber-audit-parent-', '-500-', session_id)
    expect(events(io).map { |event| event['kind'] }).to include(
      'process_progress_monitor_active', 'process_progress_monitor_completed'
    )
  ensure
    monitor&.stop
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it 'tracks independent processes and emits stall/resumption transitions' do
    monitor, io, root = build_monitor
    monitor.ingest(frame(pid: 700, generation: 11, sequence: 1, monotonic_ns: 90), now_ns: 100)
    monitor.ingest(frame(pid: 701, generation: 12, sequence: 1, monotonic_ns: 91), now_ns: 110)
    expect(monitor.poll(now_ns: 50_000_101)).to eq(1)
    monitor.ingest(frame(pid: 700, generation: 11, sequence: 3, monotonic_ns: 120), now_ns: 50_000_200)
    monitor.stop

    kinds = events(io).map { |event| event['kind'] }
    expect(kinds).to include('process_progress_process_observed',
                             'process_progress_stall_started',
                             'process_progress_stall_completed')
    expect(events(io).find { |event| event['kind'] == 'process_progress_stall_completed' }
      .fetch('measurements')).to include(
        'process_pid' => 700,
        'process_generation' => 11,
        'progress_sequence' => 3,
        'sequence_gap' => 1
      )
  ensure
    monitor&.stop
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it 'bounds identities and does not retain malformed source bytes' do
    monitor, io, root = build_monitor
    3.times do |index|
      monitor.ingest(frame(pid: 700 + index, generation: 1, sequence: 1, monotonic_ns: 1), now_ns: 10)
    end
    secret = 'private-malformed-progress-frame'
    monitor.ingest(secret * 20, now_ns: 10)
    monitor.stop

    truncation = events(io).find { |event| event['kind'] == 'process_progress_monitor_truncated' }
    expect(truncation.fetch('measurements')).to include(
      'process_limit_exhausted' => true,
      'process_count' => 2,
      'max_processes' => 2
    )
    expect(events(io).flat_map { |event| event.fetch('measurements').values })
      .to all(satisfy { |value| value.nil? || value == true || value == false || value.is_a?(Numeric) })
    expect(io.string).not_to include(secret)
  ensure
    monitor&.stop
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  it 'fails open as unsupported for malformed dependencies at ingestion' do
    monitor, io, root = build_monitor
    secret = Object.new
    expect(monitor.ingest(secret)).to eq(0)
    expect(monitor.state).to eq(:unsupported)
    expect(io.string).not_to include(secret.inspect)
  ensure
    monitor&.stop
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end
end
