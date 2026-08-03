# frozen_string_literal: true

require 'fiber_audit/runtime/sampler'

RSpec.describe FiberAudit::Runtime::Sampler do
  it 'uses one injected draw for each decision' do
    draws = [0.49, 0.5]
    sampler = described_class.new(
      policy: FiberAudit::Runtime::Policy.new(sampling_rate: 0.5),
      random: -> { draws.shift }
    )

    expect(sampler.sample?).to be(true)
    expect(sampler.sample?).to be(false)
    expect(draws).to be_empty
  end

  it 'handles zero and one sampling boundaries' do
    never = described_class.new(
      policy: FiberAudit::Runtime::Policy.new(sampling_rate: 0.0),
      random: -> { 0.0 }
    )
    always = described_class.new(
      policy: FiberAudit::Runtime::Policy.new(sampling_rate: 1.0),
      random: -> { 0.999_999 }
    )

    expect(never.sample?).to be(false)
    expect(always.sample?).to be(true)
  end

  it 'rejects invalid sources and draws' do
    policy = FiberAudit::Runtime::Policy.new
    expect { described_class.new(policy: Object.new) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { described_class.new(policy: policy, random: nil) }.to raise_error(FiberAudit::RuntimeContractError)

    [-0.1, 1.0, Float::NAN, nil].each do |draw|
      sampler = described_class.new(policy: policy, random: -> { draw })
      expect { sampler.sample? }.to raise_error(FiberAudit::RuntimeContractError)
    end
  end
end
