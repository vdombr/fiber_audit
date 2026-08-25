# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/runtime/scheduler_snapshot'
require_relative '../support/runtime_probe_harness'

RSpec.describe 'blocking Fiber conformance' do
  # RSpec-local fixture implements Ruby's required Fiber scheduler API names.
  # rubocop:disable Lint/ConstantDefinitionInBlock, Naming/PredicateMethod
  class BlockingFiberConformanceScheduler
    def fiber(&block)
      Fiber.new(blocking: false, &block).tap(&:resume)
    end

    def block(*) = true
    def unblock(*) = true
    def kernel_sleep(*) = 0
    def io_wait(*) = 0
    def fiber_interrupt(fiber, exception) = fiber.raise(exception)
    def close = nil
  end
  # rubocop:enable Lint/ConstantDefinitionInBlock, Naming/PredicateMethod

  after do
    Fiber.set_scheduler(nil) if Fiber.scheduler
    stop_probe_runtime(@runtime) if @runtime
    FiberAudit::Runtime::FiberModeContext.reset!
  end

  it 'matches blocking state and current-scheduler visibility on supported CRuby' do
    scheduler = BlockingFiberConformanceScheduler.new
    Fiber.set_scheduler(scheduler)

    blocking = Fiber.new(blocking: true) do
      FiberAudit::Runtime::SchedulerSnapshotCapture.capture
    end.resume
    nonblocking = nil
    Fiber.schedule do
      nonblocking = FiberAudit::Runtime::SchedulerSnapshotCapture.capture
    end

    expect(blocking).to have_attributes(
      scheduler_present: true,
      current_scheduler_present: false,
      scheduler_snapshot_consistent: true,
      fiber_blocking: true
    )
    expect(nonblocking).to have_attributes(
      scheduler_present: true,
      current_scheduler_present: true,
      scheduler_snapshot_consistent: true,
      fiber_blocking: false
    )
  end

  it 'records nearest explicit blocking provenance without retaining application values' do
    @runtime = start_probe_runtime
    secret = 'blocking-fiber-conformance-private-value'

    result = Fiber.new(blocking: true) do
      IO.select([], [], [], 0)
      Fiber.blocking do
        IO.select([], [], [], 0)
        secret
      end
    end.resume

    selects = probe_events(@runtime).select do |record|
      record.dig('payload', 'operation') == 'IO.select' &&
        record.dig('payload', 'kind') == 'operation_completed'
    end

    expect(result).to equal(secret)
    expect(selects.size).to eq(2)
    expect(selects.map { |record| record.dig('payload', 'measurements', 'fiber_blocking_context_depth') })
      .to eq([1, 2])
    expect(selects.first.dig('payload', 'measurements')).to include(
      'fiber_blocking' => true,
      'fiber_blocking_context_present' => true,
      'fiber_blocking_context_fiber_new' => true,
      'fiber_blocking_context_fiber_blocking' => false,
      'operation_scheduler_cooperation_available' => false
    )
    expect(selects.last.dig('payload', 'measurements')).to include(
      'fiber_blocking' => true,
      'fiber_blocking_context_present' => true,
      'fiber_blocking_context_fiber_new' => false,
      'fiber_blocking_context_fiber_blocking' => true,
      'operation_scheduler_cooperation_available' => false
    )
    expect(@runtime.io.string).not_to include(secret)
  end
end
