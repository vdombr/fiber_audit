# frozen_string_literal: true

require 'fiber_audit/runtime/limits'

RSpec.describe FiberAudit::Runtime::Limits do
  def build_limits(**policy_values)
    described_class.new(
      policy: FiberAudit::Runtime::Policy.new(sampling_rate: 1.0, **policy_values),
      started_monotonic_ns: 100
    )
  end

  def emit(limits, at: 100)
    limits.observe!
    reason = limits.preflight_event(now_ns: at)
    if reason
      limits.drop!(reason == :rate_limited ? :rate_limited : :session_event_limited)
    else
      limits.emitted!(now_ns: at)
    end
    reason
  end

  it 'enforces the session event limit before the rate limit' do
    limits = build_limits(max_events_per_session: 2, max_events_per_second: 1)
    expect(emit(limits)).to be_nil
    expect(emit(limits)).to eq(:rate_limited)

    expect(emit(limits, at: 1_000_000_100)).to be_nil
    expect(emit(limits, at: 1_000_000_101)).to eq(:session_event_limited)
  end

  it 'uses fixed session-relative half-open rate windows' do
    limits = build_limits(max_events_per_second: 1)
    expect(emit(limits, at: 1_000_000_099)).to be_nil
    expect(emit(limits, at: 1_000_000_099)).to eq(:rate_limited)
    expect(emit(limits, at: 1_000_000_100)).to be_nil
    expect(emit(limits, at: 9_000_000_100)).to be_nil
  end

  it 'does not let drops consume event or rate capacity' do
    limits = build_limits(max_events_per_second: 1, max_events_per_session: 1)
    limits.observe!
    limits.drop!(:oversize)
    limits.observe!
    limits.drop!(:session_byte_limited)

    expect(emit(limits)).to be_nil
    expect(limits.counters).to include(
      events_observed: 3,
      events_emitted: 1,
      oversize: 1,
      session_byte_limited: 1
    )
  end

  it 'tracks every counter in the session summary contract' do
    limits = build_limits
    limits.observe!
    limits.drop!(:sampled_out)
    limits.observe!
    limits.drop!(:rate_limited)
    limits.observe!
    limits.drop!(:session_event_limited)
    limits.internal_error!(count: 2)

    expect(limits.counters).to eq(
      events_observed: 3,
      events_emitted: 0,
      sampled_out: 1,
      rate_limited: 1,
      session_event_limited: 1,
      session_byte_limited: 0,
      oversize: 0,
      internal_errors: 2
    )
    expect(limits.counters).to be_frozen
  end

  it 'rejects unknown drops, reversed clocks, and times before the session' do
    limits = build_limits
    expect { limits.drop!(:secret) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { limits.preflight_event(now_ns: 99) }.to raise_error(FiberAudit::RuntimeContractError)

    expect(limits.preflight_event(now_ns: 200)).to be_nil
    expect { limits.preflight_event(now_ns: 199) }.to raise_error(FiberAudit::RuntimeSafetyError)
  end
end
