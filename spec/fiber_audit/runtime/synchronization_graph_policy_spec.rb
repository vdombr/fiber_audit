# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/runtime/synchronization_graph_policy'

RSpec.describe FiberAudit::Runtime::SynchronizationGraphPolicy do
  it 'is immutable, bounded, and disabled by default' do
    policy = described_class.new
    expect(policy.to_h).to eq(enabled: false, max_identities: 4_096, max_resources: 2_048, max_wait_edges: 2_048,
                              max_cycle_depth: 64)
    expect(policy).to be_frozen
    expect(described_class::DISABLED).to eq(policy)
  end

  it 'accepts inclusive bounds and rejects malformed fields' do
    expect(described_class.new(enabled: true, max_identities: 1, max_resources: 1, max_wait_edges: 1,
                               max_cycle_depth: 2)).to be_enabled
    expect(described_class.new(enabled: true, max_identities: 100_000, max_resources: 100_000, max_wait_edges: 100_000,
                               max_cycle_depth: 256)).to be_enabled
    expect { described_class.new(secret: 1) }.to raise_error(FiberAudit::RuntimeContractError, /unknown/)
    expect { described_class.new(enabled: 'yes') }.to raise_error(FiberAudit::RuntimeContractError, /Boolean/)
    expect { described_class.new(max_cycle_depth: 1) }.to raise_error(FiberAudit::RuntimeContractError, /max_cycle_depth/)
  end
end
