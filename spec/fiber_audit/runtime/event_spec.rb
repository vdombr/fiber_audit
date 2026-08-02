# frozen_string_literal: true

require 'fiber_audit/runtime/event'

RSpec.describe FiberAudit::Runtime::Event do
  def build_event(**overrides)
    defaults = {
      kind: :operation_completed,
      source: :instrumentation,
      occurred_at: Time.new(2026, 8, 2, 12, 0, 0, '+02:00'),
      monotonic_ns: 100,
      duration_ns: 25,
      operation: 'Mutex#lock',
      location: FiberAudit::Runtime::Location.new(path: 'app/models/user.rb', line: 4, column: 2),
      execution_context: :request,
      thread_id: 7,
      fiber_id: 9,
      measurements: { threshold_ns: 10 }
    }
    described_class.new(**defaults, **overrides)
  end

  it 'defines the exact immutable event contract' do
    expect(described_class.members).to eq(%i[
                                            kind source occurred_at monotonic_ns duration_ns operation location
                                            execution_context thread_id fiber_id measurements
                                          ])
    expect(build_event).to be_frozen
  end

  it 'normalizes identifiers, context, UTC time, and measurement keys' do
    event = build_event(kind: 'operation_completed', execution_context: 'job')

    expect(event.kind).to eq(:operation_completed)
    expect(event.execution_context).to eq(:job)
    expect(event.occurred_at.utc?).to be(true)
    expect(event.measurements).to eq('threshold_ns' => 10)
  end

  it 'owns and freezes mutable inputs' do
    operation = +'Net::HTTP.get'
    measurements = { duration_ms: 1.5 }
    event = build_event(operation: operation, measurements: measurements)
    operation.replace('changed')
    measurements[:duration_ms] = 3

    expect(event.operation).to eq('Net::HTTP.get')
    expect(event.operation).to be_frozen
    expect(event.measurements).to eq('duration_ms' => 1.5)
    expect(event.measurements).to be_frozen
  end

  it 'permits only finite scalar measurements with unique normalized keys' do
    expect { build_event(measurements: { ok: true, missing: nil, count: 1 }) }.not_to raise_error
    expect { build_event(measurements: { payload: 'secret' }) }
      .to raise_error(FiberAudit::RuntimeContractError)
    expect { build_event(measurements: { duration: Float::NAN }) }
      .to raise_error(FiberAudit::RuntimeContractError)
    expect { build_event(measurements: { count: 1, 'count' => 2 }) }
      .to raise_error(FiberAudit::RuntimeContractError, /duplicate normalized/)
  end

  it 'rejects invalid contexts, identifiers, and negative timing values' do
    expect { build_event(execution_context: :production) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { build_event(kind: :'Not Valid') }.to raise_error(FiberAudit::RuntimeContractError)
    expect { build_event(duration_ns: -1) }.to raise_error(FiberAudit::RuntimeContractError)
  end

  it 'rejects operation payloads and arbitrary URLs' do
    expect { build_event(operation: 'Net::HTTP.get https://secret.example') }
      .to raise_error(FiberAudit::RuntimeContractError)
    expect { build_event(operation: 'https://secret.example') }
      .to raise_error(FiberAudit::RuntimeContractError)
  end
end

RSpec.describe FiberAudit::Runtime::Location do
  it 'normalizes separators and dot segments' do
    location = described_class.new(path: 'app\\models/../jobs/task.rb', line: 1, column: 0)
    expect(location.path).to eq('app/jobs/task.rb')
    expect(location.path).to be_frozen
  end

  it 'accepts privacy sentinels' do
    expect(described_class.new(path: '[external]').path).to eq('[external]')
    expect(described_class.new(path: '[redacted]').path).to eq('[redacted]')
  end

  it 'rejects absolute, escaping, control-character, and invalid coordinates' do
    expect { described_class.new(path: '/tmp/secret.rb') }.to raise_error(FiberAudit::RuntimeContractError)
    expect { described_class.new(path: '../secret.rb') }.to raise_error(FiberAudit::RuntimeContractError)
    expect { described_class.new(path: "app/a.rb\n") }.to raise_error(FiberAudit::RuntimeContractError)
    expect { described_class.new(path: 'app/a.rb', line: 0) }.to raise_error(FiberAudit::RuntimeContractError)
    expect { described_class.new(path: 'app/a.rb', column: -1) }.to raise_error(FiberAudit::RuntimeContractError)
  end
end
