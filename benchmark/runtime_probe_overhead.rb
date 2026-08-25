# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Lint/EmptyBlock

require 'benchmark'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'

PROJECT_ROOT = File.expand_path('..', __dir__).freeze
WARMUP_ITERATIONS = 10
ITERATIONS = Integer(ENV.fetch('FIBER_AUDIT_BENCH_ITERATIONS', '1000'), 10)
SCENARIOS = %w[
  absent installed_inactive active_sampling_zero active_sampling_one
  synchronization_graph_active process_progress_monitor
].freeze

MonitorReader = Class.new do
  def read_nonblock(*) = :wait_readable
  def close = @closed = true
  def closed? = @closed == true
end

def run_scenario(name, iterations)
  validate_scenario!(name)
  return run_process_progress_monitor(iterations) if name == 'process_progress_monitor'

  registry = recorder = graph = nil
  summary = nil
  if name != 'absent'
    require_relative '../lib/fiber_audit/runtime'
    sampling_rate = %w[active_sampling_one synchronization_graph_active].include?(name) ? 1.0 : 0.0
    recorder, registry, graph = build_runtime(
      sampling_rate: sampling_rate,
      graph_enabled: name == 'synchronization_graph_active'
    )
    registry.deactivate if name == 'installed_inactive'
  end

  mutex = Mutex.new
  WARMUP_ITERATIONS.times { mutex.synchronize { nil } }
  elapsed = Benchmark.realtime do
    iterations.times { mutex.synchronize { nil } }
  end
  registry&.deactivate
  graph&.stop
  summary = recorder&.close
  {
    name: name,
    iterations: iterations,
    warmup_iterations: WARMUP_ITERATIONS,
    elapsed_seconds: elapsed,
    operations_per_second: iterations.fdiv(elapsed),
    nanoseconds_per_operation: elapsed.fdiv(iterations) * 1_000_000_000,
    emitted_events: summary&.events_emitted,
    sampled_out: summary&.sampled_out,
    dropped_events: summary && (summary.rate_limited + summary.session_event_limited +
      summary.session_byte_limited + summary.oversize)
  }
ensure
  registry&.deactivate
  graph&.stop
  recorder&.close unless recorder&.closed?
end

def validate_scenario!(name)
  raise ArgumentError, "unknown scenario: #{name}" unless SCENARIOS.include?(name)
end

def build_runtime(sampling_rate:, graph_enabled: false)
  policy = FiberAudit::Runtime::Policy.new(
    sampling_rate: sampling_rate,
    max_events_per_second: 10_000,
    max_events_per_session: 100_000,
    max_session_bytes: 100 * 1024 * 1024
  )
  clock = FiberAudit::Runtime::Clock.new
  session = FiberAudit::Runtime::Session.new(
    id: '123e4567-e89b-42d3-a456-426614174000',
    started_at: clock.wall_time,
    started_monotonic_ns: clock.monotonic_ns,
    policy: policy
  )
  writer = FiberAudit::Runtime::JSONL::Writer.new(
    io: StringIO.new,
    max_record_bytes: policy.max_record_bytes
  )
  recorder = FiberAudit::Runtime::Recorder.start(session: session, writer: writer, clock: clock)
  base = FiberAudit::Runtime::Probes::Base.new(
    recorder: recorder,
    clock: clock,
    redactor: FiberAudit::Runtime::Redactor.new(root: PROJECT_ROOT, policy: policy),
    active_operations: FiberAudit::Runtime::ActiveOperations.new
  )
  graph = if graph_enabled
            FiberAudit::Runtime::SynchronizationGraph.new(
              policy: FiberAudit::Runtime::SynchronizationGraphPolicy.new(enabled: true),
              recorder: recorder,
              clock: clock
            )
          end
  registry = FiberAudit::Runtime::Probes::Registry.activate(
    base: base,
    synchronization_graph: graph
  )
  [recorder, registry, graph]
rescue StandardError
  graph&.stop
  recorder&.close unless recorder&.closed?
  raise
end

def run_process_progress_monitor(iterations)
  require_relative '../lib/fiber_audit/runtime'
  require_relative '../lib/fiber_audit/runtime/process_progress_monitor'

  root = Dir.mktmpdir('fiber-audit-progress-benchmark')
  output = File.join(root, 'runtime')
  FileUtils.mkdir(output)
  runtime_policy = FiberAudit::Runtime::Policy.new(
    sampling_rate: 1.0,
    max_events_per_second: 10_000,
    max_events_per_session: 100_000
  )
  progress_policy = FiberAudit::Runtime::ProcessProgressPolicy.new(enabled: true)
  settings = FiberAudit::Runtime::Environment.build(
    policy: runtime_policy,
    output_directory: output,
    project_root: root,
    launch_id: '123e4567-e89b-42d3-a456-426614174000'
  )
  io = StringIO.new
  monitor = FiberAudit::Runtime::ProcessProgressMonitor.new(
    policy: progress_policy,
    settings: settings,
    reader: MonitorReader.new,
    session_id_source: -> { '123e4567-e89b-42d3-a456-426614174001' },
    pid_source: -> { Process.pid },
    writer_factory: lambda do |path:, max_record_bytes:|
      _path = path
      FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: max_record_bytes)
    end,
    thread_factory: ->(&) { Thread.new {} }
  )
  WARMUP_ITERATIONS.times do |index|
    monitor.ingest(
      FiberAudit::Runtime::ProcessProgressProtocol.encode(
        pid: Process.pid, generation: 1, sequence: index + 1, monotonic_ns: index + 1
      )
    )
  end
  elapsed = Benchmark.realtime do
    iterations.times do |index|
      monitor.ingest(
        FiberAudit::Runtime::ProcessProgressProtocol.encode(
          pid: Process.pid,
          generation: 1,
          sequence: WARMUP_ITERATIONS + index + 1,
          monotonic_ns: WARMUP_ITERATIONS + index + 1
        )
      )
    end
  end
  monitor.stop
  summary = JSON.parse(io.string.lines.last).fetch('payload')
  {
    name: 'process_progress_monitor',
    iterations: iterations,
    warmup_iterations: WARMUP_ITERATIONS,
    elapsed_seconds: elapsed,
    operations_per_second: iterations.fdiv(elapsed),
    nanoseconds_per_operation: elapsed.fdiv(iterations) * 1_000_000_000,
    emitted_events: summary.fetch('events_emitted'),
    sampled_out: summary.fetch('dropped').fetch('sampling'),
    dropped_events: summary.fetch('dropped').values.sum
  }
ensure
  monitor&.stop
  FileUtils.remove_entry(root) if root && File.exist?(root)
end

iterations = ITERATIONS
results = SCENARIOS.map { |scenario| run_scenario(scenario, iterations) }
puts JSON.generate('iterations' => iterations, 'scenarios' => results)

# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Lint/EmptyBlock
