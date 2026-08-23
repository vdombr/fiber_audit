# frozen_string_literal: true

require 'fiber_audit/runtime/operation_liveness_policy'

RSpec.describe FiberAudit::Runtime::OperationLivenessPolicy do
  it 'defines the frozen default contract' do
    policy = described_class.new

    expect(policy.to_h).to eq(enabled: true, poll_interval_ms: 100, long_active_threshold_ms: 1_000)
    expect(policy).to be_frozen
    expect(policy).to be_enabled
  end

  it 'converts milliseconds and uses an exclusive threshold' do
    policy = described_class.new(poll_interval_ms: 25, long_active_threshold_ms: 1_000)

    expect(policy.poll_interval_ns).to eq(25_000_000)
    expect(policy.long_active_threshold_ns).to eq(1_000_000_000)
    expect(policy.long_active?(age_ns: 1_000_000_000)).to be(false)
    expect(policy.long_active?(age_ns: 1_000_000_001)).to be(true)
  end

  it 'rejects unknown, non-Boolean, non-Integer, and out-of-range values' do
    expect { described_class.new(extra: true) }.to raise_error(FiberAudit::RuntimeContractError, /unknown/)
    expect { described_class.new(enabled: 1) }.to raise_error(FiberAudit::RuntimeContractError, /Boolean/)

    { poll_interval_ms: [0, 60_001, 1.0], long_active_threshold_ms: [0, 86_400_001, 1.0] }.each do |field, values|
      values.each do |value|
        expect { described_class.new(**{ field => value }) }.to raise_error(FiberAudit::RuntimeContractError, /#{field}/)
      end
    end
  end

  it 'rejects invalid active-operation ages' do
    policy = described_class.new

    expect { policy.long_active?(age_ns: -1) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { policy.long_active?(age_ns: 1.0) }.to raise_error(FiberAudit::RuntimeContractError)
  end
end
