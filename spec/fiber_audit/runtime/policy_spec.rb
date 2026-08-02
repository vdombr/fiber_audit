# frozen_string_literal: true

require 'fiber_audit/runtime/policy'

RSpec.describe FiberAudit::Runtime::Policy do
  subject(:policy) { described_class.new }

  it 'defines the frozen safety contract and conservative defaults' do
    expect(described_class.members).to eq(%i[
                                            redaction sampling_rate max_events_per_second max_events_per_session
                                            max_record_bytes max_session_bytes fail_open
                                          ])
    expect(policy.to_h).to eq(
      redaction: :strict,
      sampling_rate: 0.1,
      max_events_per_second: 100,
      max_events_per_session: 10_000,
      max_record_bytes: 16_384,
      max_session_bytes: 10_485_760,
      fail_open: true
    )
    expect(policy).to be_frozen
  end

  it 'accepts explicit values at every supported boundary' do
    minimum = described_class.new(
      sampling_rate: 0, max_events_per_second: 1, max_events_per_session: 1,
      max_record_bytes: 1_024, max_session_bytes: 4_096, fail_open: false
    )
    maximum = described_class.new(
      sampling_rate: 1, max_events_per_second: 10_000, max_events_per_session: 1_000_000,
      max_record_bytes: 1_048_576, max_session_bytes: 1_073_741_824
    )

    expect(minimum.sampling_rate).to eq(0.0)
    expect(maximum.sampling_rate).to eq(1.0)
  end

  it 'rejects unsupported redaction and invalid Boolean values' do
    expect { described_class.new(redaction: :none) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { described_class.new(fail_open: nil) }.to raise_error(FiberAudit::RuntimeContractError)
  end

  it 'rejects non-finite or out-of-range sampling rates' do
    [-0.1, 1.1, Float::NAN, Float::INFINITY].each do |value|
      expect { described_class.new(sampling_rate: value) }
        .to raise_error(FiberAudit::RuntimeContractError)
    end
  end

  it 'rejects invalid limits and a record limit larger than the session limit' do
    expect { described_class.new(max_events_per_second: 0) }
      .to raise_error(FiberAudit::RuntimeContractError)
    expect { described_class.new(max_record_bytes: 8_192, max_session_bytes: 4_096) }
      .to raise_error(FiberAudit::RuntimeContractError)
  end

  it 'makes sampling decisions from an injected draw' do
    expect(policy.sample?(draw: 0.099)).to be(true)
    expect(policy.sample?(draw: 0.1)).to be(false)
    expect { policy.sample?(draw: 1.0) }.to raise_error(FiberAudit::RuntimeContractError)
  end

  it 'provides pure count and byte-limit predicates' do
    expect(policy.rate_allowed?(emitted_in_window: 99)).to be(true)
    expect(policy.rate_allowed?(emitted_in_window: 100)).to be(false)
    expect(policy.session_event_allowed?(emitted_events: 9_999)).to be(true)
    expect(policy.record_size_allowed?(bytes: 16_384)).to be(true)
    expect(policy.session_bytes_allowed?(written_bytes: 10_000_000, next_record_bytes: 485_760)).to be(true)
    expect(policy.session_bytes_allowed?(written_bytes: 10_000_000, next_record_bytes: 485_761)).to be(false)
  end

  it 'exposes explicit safety predicates' do
    expect(policy).to be_fail_open
    expect(policy).to be_strict_redaction
  end
end
