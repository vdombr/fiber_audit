# frozen_string_literal: true

require 'fiber_audit/runtime/clock'

RSpec.describe FiberAudit::Runtime::Clock do
  it 'reads injected UTC-normalized wall and monotonic time' do
    clock = described_class.new(
      wall: -> { Time.new(2026, 8, 2, 14, 0, 0, '+02:00') },
      monotonic: -> { 123 }
    )

    expect(clock.wall_time).to eq(Time.utc(2026, 8, 2, 12))
    expect(clock.wall_time).to be_utc
    expect(clock.monotonic_ns).to eq(123)
  end

  it 'does not call sources during construction' do
    wall = -> { raise 'wall called' }
    monotonic = -> { raise 'monotonic called' }

    expect { described_class.new(wall: wall, monotonic: monotonic) }.not_to raise_error
  end

  it 'validates source interfaces and returned values' do
    expect { described_class.new(wall: nil) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { described_class.new(monotonic: nil) }.to raise_error(FiberAudit::RuntimeContractError)

    expect { described_class.new(wall: -> { 'now' }).wall_time }
      .to raise_error(FiberAudit::RuntimeContractError)
    [-1, 1.5, nil].each do |value|
      expect { described_class.new(monotonic: -> { value }).monotonic_ns }
        .to raise_error(FiberAudit::RuntimeContractError)
    end
    expect { described_class.new(monotonic: -> { described_class::MAX_NANOSECONDS + 1 }).monotonic_ns }
      .to raise_error(FiberAudit::RuntimeSafetyError)
  end

  it 'propagates source exceptions unchanged' do
    error = IOError.new('clock failed')
    expect { described_class.new(monotonic: -> { raise error }).monotonic_ns }
      .to raise_error(error)
  end
end
