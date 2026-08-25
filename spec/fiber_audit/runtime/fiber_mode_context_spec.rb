# frozen_string_literal: true

require 'fiber_audit/runtime/fiber_mode_context'

RSpec.describe FiberAudit::Runtime::FiberModeContext do
  before { described_class.reset! }
  after { described_class.reset! }

  it 'reports bounded scalar absence outside an explicit region' do
    expect(described_class.current).to be_nil
    expect(described_class.measurements).to eq(
      fiber_blocking_context_present: false,
      fiber_blocking_context_depth: 0,
      fiber_blocking_context_fiber_new: false,
      fiber_blocking_context_fiber_blocking: false,
      fiber_blocking_context_truncated: false
    )
  end

  it 'tracks nested regions and restores the outer provenance' do
    described_class.with(:fiber_new) do
      expect(described_class.current).to eq(:fiber_new)
      described_class.with('fiber_blocking') do
        expect(described_class.measurements).to include(
          fiber_blocking_context_depth: 2,
          fiber_blocking_context_fiber_blocking: true
        )
      end
      expect(described_class.current).to eq(:fiber_new)
    end
    expect(described_class.current).to be_nil
  end

  it 'preserves return and exception identity' do
    value = Object.new
    expect(described_class.with(:fiber_blocking) { value }).to equal(value)
    error = Class.new(StandardError).new('private-message')
    expect { described_class.with(:fiber_new) { raise error } }
      .to(raise_error { |raised| expect(raised).to equal(error) })
  end

  it 'does not inherit provenance into a child Fiber' do
    result = described_class.with(:fiber_blocking) do
      Fiber.new { described_class.measurements }.resume
    end
    expect(result).to include(fiber_blocking_context_present: false, fiber_blocking_context_depth: 0)
  end

  it 'caps depth and exposes truncation' do
    descend = lambda do |remaining|
      remaining.zero? ? described_class.measurements : described_class.with(:fiber_blocking) { descend.call(remaining - 1) }
    end
    expect(descend.call(described_class::MAX_DEPTH + 2)).to include(
      fiber_blocking_context_depth: described_class::MAX_DEPTH,
      fiber_blocking_context_truncated: true
    )
  end

  it 'rejects unknown kinds before application code' do
    called = false
    expect { described_class.with(:unknown) { called = true } }
      .to raise_error(FiberAudit::RuntimeContractError, /unknown Fiber mode context/)
    expect(called).to be(false)
  end
end
