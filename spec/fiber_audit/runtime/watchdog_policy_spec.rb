# frozen_string_literal: true

require 'fiber_audit/runtime/watchdog_policy'

RSpec.describe FiberAudit::Runtime::WatchdogPolicy do
  it 'defines the frozen default watchdog contract' do
    policy = described_class.new

    expect(policy.members).to eq(%i[enabled heartbeat_interval_ms stall_threshold_ms max_frames])
    expect(policy.to_h).to eq(
      enabled: true,
      heartbeat_interval_ms: 25,
      stall_threshold_ms: 100,
      max_frames: 20
    )
    expect(policy).to be_frozen
    expect(policy).to be_enabled
  end

  it 'accepts every supported boundary and converts milliseconds exactly' do
    minimum = described_class.new(heartbeat_interval_ms: 1, stall_threshold_ms: 1, max_frames: 0)
    maximum = described_class.new(
      heartbeat_interval_ms: 60_000,
      stall_threshold_ms: 600_000,
      max_frames: 100
    )

    expect(minimum.heartbeat_interval_ns).to eq(1_000_000)
    expect(minimum.stall_threshold_ns).to eq(1_000_000)
    expect(maximum.heartbeat_interval_ns).to eq(60_000_000_000)
    expect(maximum.stall_threshold_ns).to eq(600_000_000_000)
  end

  it 'starts a stall only after the exact threshold' do
    policy = described_class.new(stall_threshold_ms: 100)

    expect(policy.stalled?(age_ns: 100_000_000)).to be(false)
    expect(policy.stalled?(age_ns: 100_000_001)).to be(true)
  end

  it 'rejects unknown fields, non-Booleans, and out-of-range values' do
    expect { described_class.new(extra: true) }.to raise_error(FiberAudit::RuntimeContractError, /unknown/)
    expect { described_class.new(enabled: 1) }.to raise_error(FiberAudit::RuntimeContractError, /Boolean/)

    {
      heartbeat_interval_ms: [0, 60_001, 1.0],
      stall_threshold_ms: [0, 600_001, 1.0],
      max_frames: [-1, 101, 1.0]
    }.each do |field, invalid_values|
      invalid_values.each do |value|
        expect { described_class.new(**{ field => value }) }
          .to raise_error(FiberAudit::RuntimeContractError, /#{field}/)
      end
    end
  end

  it 'rejects invalid heartbeat ages' do
    policy = described_class.new

    expect { policy.stalled?(age_ns: -1) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { policy.stalled?(age_ns: 1.0) }.to raise_error(FiberAudit::RuntimeContractError)
  end
end
