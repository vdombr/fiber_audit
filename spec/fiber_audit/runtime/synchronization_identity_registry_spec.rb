# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/runtime/synchronization_identity_registry'

RSpec.describe FiberAudit::Runtime::SynchronizationIdentityRegistry do
  it 'assigns stable opaque IDs and enforces its bound' do
    registry = described_class.new(capacity: 2)
    first = Object.new
    second = Object.new
    expect(registry.id_for(first)).to eq(1)
    expect(registry.id_for(first)).to eq(1)
    expect(registry.id_for(second)).to eq(2)
    expect(registry.id_for(Object.new)).to be_nil
    expect(registry).to be_truncated
    expect([1, 2]).not_to include(first.object_id, second.object_id)
  end

  it 'clears state and resets after a PID change' do
    pid = 100
    registry = described_class.new(capacity: 2, pid_source: -> { pid })
    object = Object.new
    expect(registry.id_for(object)).to eq(1)
    pid = 101
    expect(registry.id_for(object)).to eq(1)
    expect(registry.size).to eq(1)
    expect(registry.clear!).to equal(registry)
    expect(registry.size).to eq(0)
  end

  it 'rejects malformed dependencies and nil identities' do
    expect { described_class.new(capacity: 0) }.to raise_error(FiberAudit::RuntimeContractError, /capacity/)
    expect do
      described_class.new(capacity: 1, pid_source: nil)
    end.to raise_error(FiberAudit::RuntimeContractError, /pid_source/)
    expect { described_class.new(capacity: 1).id_for(nil) }.to raise_error(FiberAudit::RuntimeContractError, /nil/)
  end
end
