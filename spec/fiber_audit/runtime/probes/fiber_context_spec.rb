# frozen_string_literal: true

require 'stringio'
require 'fiber_audit/runtime/probes/fiber_context'
require 'fiber_audit/runtime/probes/registry'

RSpec.describe FiberAudit::Runtime::Probes::FiberContext do
  def runtime
    policy = FiberAudit::Runtime::Policy.new(sampling_rate: 1.0)
    io = StringIO.new
    session = FiberAudit::Runtime::Session.new(
      id: '123e4567-e89b-42d3-a456-426614174000',
      started_at: Time.utc(2026, 8, 2, 12),
      started_monotonic_ns: 1,
      policy: policy
    )
    clock = FiberAudit::Runtime::Clock.new(wall: -> { Time.utc(2026, 8, 2, 12) }, monotonic: -> { 1 })
    recorder = FiberAudit::Runtime::Recorder.start(
      session: session,
      writer: FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: policy.max_record_bytes),
      clock: clock,
      random: -> { 0.0 }
    )
    base = FiberAudit::Runtime::Probes::Base.new(
      recorder: recorder,
      clock: clock,
      redactor: FiberAudit::Runtime::Redactor.new(root: Dir.pwd, policy: policy),
      active_operations: FiberAudit::Runtime::ActiveOperations.new
    )
    registry = FiberAudit::Runtime::Probes::Registry.activate(base: base)
    [registry, recorder, io]
  end

  after do
    FiberAudit::Runtime::Probes::Registry.deactivate(@registry) if @registry
    FiberAudit::Runtime::FiberModeContext.reset!
  end

  it 'delays Fiber.new provenance until execution and preserves result identity' do
    @registry, recorder, io = runtime
    value = Object.new
    fiber = Fiber.new(blocking: true) { |argument| [argument, FiberAudit::Runtime::FiberModeContext.measurements] }
    result, measurements = fiber.resume(value)

    expect(result).to equal(value)
    expect(measurements).to include(fiber_blocking_context_present: true, fiber_blocking_context_fiber_new: true)
    recorder.close
    expect(io.string).to include('Fiber.new(blocking: true)')
  end

  it 'does not classify omitted or false blocking forms' do
    @registry, recorder, io = runtime
    Fiber.new(blocking: false) { false }.resume
    Fiber.new { :omitted }.resume
    recorder.close
    expect(io.string).not_to include('Fiber.new(blocking: true)')
  end

  it 'preserves Fiber.blocking return and exception identity' do
    @registry, recorder, io = runtime
    value = Object.new
    expect(Fiber.blocking { value }).to equal(value)
    error = Class.new(StandardError).new('private-application-message')
    expect { Fiber.blocking { raise error } }.to(raise_error { |raised| expect(raised).to equal(error) })
    recorder.close
    expect(io.string).not_to include(error.message)
  end
end
