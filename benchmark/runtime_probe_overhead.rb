#!/usr/bin/env ruby
# frozen_string_literal: true

require 'benchmark'
require 'json'
require 'open3'
require 'rbconfig'
require 'stringio'

# rubocop:disable Metrics/AbcSize
module RuntimeProbeOverhead
  SCENARIOS = %w[absent installed_inactive active_sampling_zero active_sampling_one].freeze
  DEFAULT_ITERATIONS = 2_000
  WARMUP_ITERATIONS = 200
  PROJECT_ROOT = File.expand_path('..', __dir__).freeze
  SCENARIO_KEY = 'FIBER_AUDIT_BENCH_SCENARIO'
  ITERATIONS_KEY = 'FIBER_AUDIT_BENCH_ITERATIONS'

  module_function

  def run_scenario(name, iterations)
    validate_scenario!(name)
    registry = nil
    recorder = nil
    summary = nil
    if name != 'absent'
      require_relative '../lib/fiber_audit/runtime'
      sampling_rate = name == 'active_sampling_one' ? 1.0 : 0.0
      recorder, registry = build_runtime(sampling_rate: sampling_rate)
      registry.deactivate if name == 'installed_inactive'
    end

    mutex = Mutex.new
    WARMUP_ITERATIONS.times { mutex.synchronize { nil } }
    elapsed = Benchmark.realtime do
      iterations.times { mutex.synchronize { nil } }
    end
    registry&.deactivate
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
    recorder&.close unless recorder&.closed?
  end

  def build_runtime(sampling_rate:)
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
    [recorder, FiberAudit::Runtime::Probes::Registry.activate(base: base)]
  end

  def run_all(iterations)
    SCENARIOS.map do |name|
      environment = { SCENARIO_KEY => name, ITERATIONS_KEY => iterations.to_s }
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, __FILE__)
      raise "benchmark scenario #{name} failed: #{stderr}" unless status.success?

      JSON.parse(stdout)
    end
  end

  def iterations_from_environment
    value = Integer(ENV.fetch(ITERATIONS_KEY, DEFAULT_ITERATIONS.to_s), 10)
    raise ArgumentError, 'benchmark iterations must be positive' unless value.positive?

    value
  end

  def validate_scenario!(name)
    return if SCENARIOS.include?(name)

    raise ArgumentError, "unknown benchmark scenario: #{name.inspect}"
  end
end

iterations = RuntimeProbeOverhead.iterations_from_environment
# rubocop:enable Metrics/AbcSize
scenario = ENV.fetch(RuntimeProbeOverhead::SCENARIO_KEY, nil)
if scenario
  puts JSON.generate(RuntimeProbeOverhead.run_scenario(scenario, iterations))
else
  puts JSON.pretty_generate(
    ruby: RUBY_DESCRIPTION,
    iterations: iterations,
    timing_gate: false,
    scenarios: RuntimeProbeOverhead.run_all(iterations)
  )
end
