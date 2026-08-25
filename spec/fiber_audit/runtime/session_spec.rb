# frozen_string_literal: true

require 'fiber_audit/runtime/session'

RSpec.describe FiberAudit::Runtime::Session do
  let(:uuid) { '123e4567-e89b-42d3-a456-426614174000' }

  def build_session(**overrides)
    described_class.new(
      id: uuid,
      started_at: Time.new(2026, 8, 2, 10, 0, 0, '+02:00'),
      started_monotonic_ns: 10,
      **overrides
    )
  end

  it 'defines the exact immutable versioned session contract' do
    expect(described_class.members).to eq(%i[
                                            id started_at started_monotonic_ns schema_version process_role
                                            policy tool_version ruby_version
                                          ])
    expect(build_session).to be_frozen
  end

  it 'defaults to JSONL 1.1 audited-process sessions' do
    session = build_session
    expect(session.schema_version).to eq('1.1')
    expect(session.process_role).to eq(:audited_process)
    expect(session.tool_version).to eq(FiberAudit::VERSION)
    expect(session.ruby_version).to eq(RUBY_VERSION)
    expect(session.started_at.utc?).to be(true)
    expect(session.policy).to be_a(FiberAudit::Runtime::Policy)
  end

  it 'accepts explicit 1.0 and parent-monitor 1.1 sessions' do
    expect(build_session(schema_version: '1.0').process_role).to eq(:audited_process)
    expect(build_session(process_role: :parent_monitor).schema_version).to eq('1.1')
  end

  it 'rejects unsupported versions, roles, and a parent role under 1.0' do
    expect { build_session(schema_version: '2.0') }.to raise_error(FiberAudit::RuntimeContractError, /schema_version/)
    expect { build_session(process_role: :worker) }.to raise_error(FiberAudit::RuntimeContractError, /process_role/)
    expect { build_session(schema_version: '1.0', process_role: :parent_monitor) }
      .to raise_error(FiberAudit::RuntimeContractError, /1\.0 sessions/)
  end

  it 'uses version defaults and normalizes time to UTC' do
    session = build_session
    expect(session.tool_version).to eq(FiberAudit::VERSION)
    expect(session.ruby_version).to eq(RUBY_VERSION)
    expect(session.started_at.utc?).to be(true)
    expect(session.policy).to be_a(FiberAudit::Runtime::Policy)
  end

  it 'owns String values supplied by callers' do
    id = uuid.dup
    version = +'0.2.0'
    session = build_session(id: id, tool_version: version)
    id.replace('changed')
    version.replace('changed')

    expect(session.id).to eq(uuid)
    expect(session.tool_version).to eq('0.2.0')
    expect(session.id).to be_frozen
  end

  it 'rejects noncanonical UUIDs, invalid policies, and negative monotonic time' do
    expect { build_session(id: uuid.upcase) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { build_session(policy: {}) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { build_session(started_monotonic_ns: -1) }.to raise_error(FiberAudit::RuntimeContractError)
  end
end

RSpec.describe FiberAudit::Runtime::SessionSummary do
  def build_summary(**overrides)
    defaults = {
      ended_at: Time.utc(2026, 8, 2, 12),
      ended_monotonic_ns: 500,
      status: :completed,
      events_observed: 10,
      events_emitted: 4,
      sampled_out: 3,
      rate_limited: 1,
      session_event_limited: 1,
      session_byte_limited: 0,
      oversize: 1,
      internal_errors: 0
    }
    described_class.new(**defaults, **overrides)
  end

  it 'defines exact statuses and counter fields' do
    expect(described_class.members).to eq(%i[
                                            ended_at ended_monotonic_ns status events_observed events_emitted sampled_out
                                            rate_limited session_event_limited session_byte_limited oversize internal_errors
                                          ])
    expect(described_class::STATUSES).to eq(%i[completed degraded aborted])
  end

  it 'accepts every status and freezes the result' do
    described_class::STATUSES.each do |status|
      expect(build_summary(status: status)).to be_frozen
    end
  end

  it 'rejects invalid status, counters, and over-accounting' do
    expect { build_summary(status: :running) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { build_summary(internal_errors: -1) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { build_summary(events_observed: 9) }.to raise_error(FiberAudit::RuntimeContractError)
  end
end
