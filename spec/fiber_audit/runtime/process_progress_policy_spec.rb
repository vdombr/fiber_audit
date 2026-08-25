# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/runtime/process_progress_policy'

RSpec.describe FiberAudit::Runtime::ProcessProgressPolicy do
  it 'is disabled and bounded by default' do
    policy = described_class.new
    expect(policy.to_h).to eq(enabled: false, heartbeat_interval_ms: 50, stall_threshold_ms: 250,
                              max_processes: 1_024, max_frames_per_poll: 256, max_buffer_bytes: 65_536)
    expect(policy).to be_frozen
    expect(described_class::DISABLED).to eq(policy)
  end

  it 'derives strict monotonic thresholds' do
    policy = described_class.new(enabled: true, heartbeat_interval_ms: 20, stall_threshold_ms: 125)
    expect(policy.heartbeat_interval_ns).to eq(20_000_000)
    expect(policy.stalled?(age_ns: 125_000_000)).to be(false)
    expect(policy.stalled?(age_ns: 125_000_001)).to be(true)
  end

  it 'rejects unknown and contradictory values' do
    expect { described_class.new(secret: 1) }.to raise_error(FiberAudit::RuntimeContractError, /unknown/)
    expect { described_class.new(enabled: 'yes') }.to raise_error(FiberAudit::RuntimeContractError, /Boolean/)
    expect { described_class.new(heartbeat_interval_ms: 100, stall_threshold_ms: 100) }
      .to raise_error(FiberAudit::RuntimeContractError, /greater/)
  end
end
