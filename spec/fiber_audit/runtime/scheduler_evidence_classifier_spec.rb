# frozen_string_literal: true

require 'fiber_audit/runtime/scheduler_evidence_classifier'

RSpec.describe FiberAudit::Runtime::SchedulerEvidenceClassifier do
  def snapshot(scheduler_present:, fiber_blocking:, consistent: true, **capabilities)
    FiberAudit::Runtime::SchedulerSnapshot.new(
      scheduler_present: scheduler_present,
      current_scheduler_present: scheduler_present,
      scheduler_snapshot_consistent: consistent,
      fiber_blocking: fiber_blocking,
      **capabilities
    )
  end

  it 'makes zero-timeout select polling inapplicable' do
    measurements = described_class.measurements(
      operation: 'IO.select',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false,
                                   scheduler_io_select_supported: false),
      invocation_measurements: { timeout_present: true, timeout_zero: true }
    )
    expect(measurements).to include(
      operation_optional_capability_required: true,
      operation_optional_capability_applicable: false,
      operation_optional_capability_supported: nil,
      operation_scheduler_cooperation_available: true
    )
  end

  it 'classifies core and optional requirements independently' do
    measurements = described_class.measurements(
      operation: 'Net::HTTP.request',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false,
                                   scheduler_io_wait_supported: true,
                                   scheduler_address_resolve_supported: true),
      invocation_measurements: { endpoint_resolution_applicable: true }
    )
    expect(measurements).to include(
      operation_core_capability_required: true,
      operation_core_capability_supported: true,
      operation_optional_capability_required: true,
      operation_optional_capability_applicable: true,
      operation_optional_capability_supported: true,
      operation_scheduler_cooperation_available: true
    )
    expect(measurements).to be_frozen
  end

  it 'does not require an inapplicable optional capability' do
    measurements = described_class.measurements(
      operation: 'Net::HTTP.request',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false,
                                   scheduler_io_wait_supported: true,
                                   scheduler_address_resolve_supported: false),
      invocation_measurements: { endpoint_resolution_applicable: false }
    )
    expect(measurements).to include(
      operation_optional_capability_applicable: false,
      operation_optional_capability_supported: nil,
      operation_scheduler_cooperation_available: true
    )
  end

  it 'keeps conditional applicability unknown until invocation evidence exists' do
    measurements = described_class.measurements(
      operation: 'Net::HTTP.request',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false,
                                   scheduler_io_wait_supported: true,
                                   scheduler_address_resolve_supported: true)
    )
    expect(measurements).to include(
      operation_optional_capability_applicable: nil,
      operation_optional_capability_supported: nil,
      operation_scheduler_cooperation_available: nil
    )
  end

  it 'never promotes an inconsistent snapshot to cooperation' do
    measurements = described_class.measurements(
      operation: 'Mutex#lock',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false, consistent: false,
                                   scheduler_block_supported: true)
    )
    expect(measurements[:operation_core_capability_supported]).to be(true)
    expect(measurements[:operation_scheduler_cooperation_available]).to be_nil
  end

  it 'distinguishes absence, blocking Fibers, missing support, and unknown state' do
    absent = described_class.measurements(operation: 'Process.wait',
                                          scheduler_snapshot: snapshot(
                                            scheduler_present: false, fiber_blocking: true
                                          ))
    blocking = described_class.measurements(operation: 'Process.wait',
                                            scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: true,
                                                                         scheduler_process_wait_supported: true))
    unsupported = described_class.measurements(operation: 'Process.wait',
                                               scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false,
                                                                            scheduler_process_wait_supported: false))
    unknown = described_class.measurements(operation: 'Process.wait', scheduler_snapshot: nil)

    expect(absent[:operation_scheduler_cooperation_available]).to be(false)
    expect(blocking[:operation_scheduler_cooperation_available]).to be(false)
    expect(unsupported[:operation_scheduler_cooperation_available]).to be(false)
    expect(unknown[:operation_scheduler_cooperation_available]).to be_nil
  end

  it 'returns all-unknown measurements for an unknown operation' do
    expect(described_class.measurements(operation: 'Project.perform', scheduler_snapshot: nil).values)
      .to all(be_nil)
  end
end
