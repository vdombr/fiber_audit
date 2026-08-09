# frozen_string_literal: true

require 'json'
require 'stringio'

module RuntimeProbeHarness
  ProbeRuntime = Data.define(:registry, :recorder, :io)

  def start_probe_runtime(fail_open: true, sampling_rate: 1.0)
    policy = FiberAudit::Runtime::Policy.new(
      sampling_rate: sampling_rate,
      fail_open: fail_open,
      max_events_per_second: 1_000,
      max_events_per_session: 10_000
    )
    io = StringIO.new
    tick = 100
    clock = FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12) },
      monotonic: -> { tick += 10 }
    )
    session = FiberAudit::Runtime::Session.new(
      id: '123e4567-e89b-42d3-a456-426614174000',
      started_at: Time.utc(2026, 8, 2, 12),
      started_monotonic_ns: 100,
      policy: policy
    )
    writer = FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: policy.max_record_bytes)
    recorder = FiberAudit::Runtime::Recorder.start(session: session, writer: writer, clock: clock, random: -> { 0.0 })
    operations = FiberAudit::Runtime::ActiveOperations.new
    base = FiberAudit::Runtime::Probes::Base.new(
      recorder: recorder,
      clock: clock,
      redactor: FiberAudit::Runtime::Redactor.new(root: Dir.pwd, policy: policy),
      active_operations: operations
    )
    registry = FiberAudit::Runtime::Probes::Registry.activate(base: base)
    ProbeRuntime.new(registry: registry, recorder: recorder, io: io)
  end

  def stop_probe_runtime(runtime)
    FiberAudit::Runtime::Probes::Registry.deactivate(runtime.registry)
    runtime.recorder.close unless runtime.recorder.closed?
  end

  def probe_events(runtime)
    runtime.io.string.lines.map { |line| JSON.parse(line) }.select do |record|
      record['record_type'] == 'event' && record.dig('payload', 'source') == 'targeted_probe'
    end
  end

  def operations(runtime)
    probe_events(runtime).map { |record| record.dig('payload', 'operation') }
  end
end

RSpec.configure do |config|
  config.include RuntimeProbeHarness
end
