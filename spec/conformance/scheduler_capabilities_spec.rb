# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/runtime/scheduler_evidence_classifier'
require 'fiber_audit/runtime/scheduler_snapshot'

RSpec.describe 'scheduler capability conformance' do
  # RSpec-local fixtures implement Ruby's required Fiber scheduler API names.
  # rubocop:disable Lint/ConstantDefinitionInBlock, Naming/PredicateMethod
  class CoreOnlyConformanceScheduler
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

  class OptionalConformanceScheduler < CoreOnlyConformanceScheduler
    def io_select(*) = nil
    def process_wait(*) = nil
    def address_resolve(*) = []
  end
  # rubocop:enable Lint/ConstantDefinitionInBlock, Naming/PredicateMethod

  after do
    Fiber.set_scheduler(nil) if Fiber.scheduler
  end

  it 'captures core and absent optional capability subsets inside a nonblocking Fiber' do
    snapshot = capture_snapshot(CoreOnlyConformanceScheduler.new)

    expect(snapshot).to have_attributes(
      scheduler_present: true,
      current_scheduler_present: true,
      scheduler_snapshot_consistent: true,
      fiber_blocking: false,
      scheduler_block_supported: true,
      scheduler_kernel_sleep_supported: true,
      scheduler_io_wait_supported: true,
      scheduler_io_select_supported: false,
      scheduler_process_wait_supported: false,
      scheduler_address_resolve_supported: false
    )
  end

  it 'requires optional endpoint resolution only when the invocation can resolve a name' do
    snapshot = capture_snapshot(CoreOnlyConformanceScheduler.new)
    named = classify(
      'Net::HTTP.request',
      snapshot,
      endpoint_resolution_applicable: true
    )
    numeric = classify(
      'Net::HTTP.request',
      snapshot,
      endpoint_resolution_applicable: false
    )

    expect(named).to include(
      operation_core_capability_required: true,
      operation_core_capability_supported: true,
      operation_optional_capability_required: true,
      operation_optional_capability_applicable: true,
      operation_optional_capability_supported: false,
      operation_scheduler_cooperation_available: false
    )
    expect(numeric).to include(
      operation_core_capability_supported: true,
      operation_optional_capability_applicable: false,
      operation_optional_capability_supported: nil,
      operation_scheduler_cooperation_available: true
    )
  end

  it 'treats zero-timeout select as polling without inventing optional support' do
    measurements = classify(
      'IO.select',
      capture_snapshot(CoreOnlyConformanceScheduler.new),
      timeout_present: true,
      timeout_zero: true
    )

    expect(measurements).to include(
      operation_wait_possible: true,
      operation_optional_capability_required: true,
      operation_optional_capability_applicable: false,
      operation_optional_capability_supported: nil,
      operation_scheduler_cooperation_available: true
    )
  end

  it 'distinguishes absent and present always-applicable optional hooks' do
    absent = classify('Process.wait', capture_snapshot(CoreOnlyConformanceScheduler.new))
    present = classify('Process.wait', capture_snapshot(OptionalConformanceScheduler.new))

    expect(absent).to include(
      operation_optional_capability_applicable: true,
      operation_optional_capability_supported: false,
      operation_scheduler_cooperation_available: false
    )
    expect(present).to include(
      operation_optional_capability_applicable: true,
      operation_optional_capability_supported: true,
      operation_scheduler_cooperation_available: true
    )
  end

  def capture_snapshot(scheduler)
    snapshot = nil
    Fiber.set_scheduler(scheduler)
    Fiber.schedule do
      snapshot = FiberAudit::Runtime::SchedulerSnapshotCapture.capture
    end
    snapshot
  ensure
    Fiber.set_scheduler(nil) if Fiber.scheduler
  end

  def classify(operation, snapshot, invocation_measurements = {})
    FiberAudit::Runtime::SchedulerEvidenceClassifier.measurements(
      operation: operation,
      scheduler_snapshot: snapshot,
      invocation_measurements: invocation_measurements
    )
  end
end
