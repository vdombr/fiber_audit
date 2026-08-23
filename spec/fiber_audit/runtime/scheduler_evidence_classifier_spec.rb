# frozen_string_literal: true

require 'fiber_audit/runtime/scheduler_evidence_classifier'

RSpec.describe FiberAudit::Runtime::SchedulerEvidenceClassifier do
  def snapshot(scheduler_present:, fiber_blocking:, process_wait: nil)
    FiberAudit::Runtime::SchedulerSnapshot.new(
      scheduler_present: scheduler_present,
      fiber_blocking: fiber_blocking,
      scheduler_process_wait_supported: process_wait
    )
  end

  it 'classifies scheduler absence and unknown snapshots without inventing support' do
    absent = described_class.measurements(
      operation: 'Process.wait',
      scheduler_snapshot: snapshot(scheduler_present: false, fiber_blocking: nil)
    )
    unknown = described_class.measurements(
      operation: 'Process.wait',
      scheduler_snapshot: snapshot(scheduler_present: nil, fiber_blocking: nil)
    )

    expect(absent).to include(
      operation_wait_possible: true,
      operation_scheduler_capability_required: true,
      operation_scheduler_capability_supported: nil,
      operation_scheduler_cooperation_available: false
    )
    expect(unknown.values_at(
             :operation_scheduler_capability_supported,
             :operation_scheduler_cooperation_available
           )).to eq([nil, nil])
  end

  it 'distinguishes a blocking Fiber and optional hook presence or absence' do
    blocking = described_class.measurements(
      operation: 'Process.wait',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: true, process_wait: true)
    )
    supported = described_class.measurements(
      operation: 'Process.wait',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false, process_wait: true)
    )
    missing = described_class.measurements(
      operation: 'Process.wait',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false, process_wait: false)
    )

    expect(blocking[:operation_scheduler_cooperation_available]).to be(false)
    expect(supported[:operation_scheduler_cooperation_available]).to be(true)
    expect(missing[:operation_scheduler_cooperation_available]).to be(false)
  end

  it 'maps required coordination hooks to known scheduler presence' do
    measurements = described_class.measurements(
      operation: 'ConditionVariable#wait',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false)
    )

    expect(measurements).to include(
      operation_scheduler_capability_required: true,
      operation_scheduler_capability_supported: true,
      operation_scheduler_cooperation_available: true
    )
  end

  it 'keeps inventory-only and unmeasured capability evidence explicit' do
    inventory = described_class.measurements(operation: 'Kernel.spawn', scheduler_snapshot: nil)
    stream = described_class.measurements(
      operation: 'IO.popen',
      scheduler_snapshot: snapshot(scheduler_present: true, fiber_blocking: false)
    )

    expect(inventory).to include(
      operation_wait_possible: false,
      operation_inventory_only: true,
      operation_scheduler_capability_required: false,
      operation_scheduler_cooperation_available: nil
    )
    expect(stream).to include(
      operation_wait_possible: true,
      operation_inventory_only: false,
      operation_scheduler_capability_required: false,
      operation_scheduler_capability_supported: nil,
      operation_scheduler_cooperation_available: nil
    )
  end

  it 'returns all-unknown semantic measurements for an unknown operation' do
    measurements = described_class.measurements(operation: 'Project.perform', scheduler_snapshot: nil)

    expect(measurements.values).to all(be_nil)
    expect(measurements).to be_frozen
  end
end
