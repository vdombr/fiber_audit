# frozen_string_literal: true

require 'fiber_audit/runtime/jsonl/schema'

RSpec.describe FiberAudit::Runtime::JSONL::Schema do
  let(:session_id) { '123e4567-e89b-42d3-a456-426614174000' }
  let(:session) do
    FiberAudit::Runtime::Session.new(
      id: session_id,
      started_at: Time.utc(2026, 8, 2, 12),
      started_monotonic_ns: 100,
      policy: FiberAudit::Runtime::Policy.new(sampling_rate: 1.0),
      tool_version: '0.2.0',
      ruby_version: '3.4.9'
    )
  end
  let(:event) do
    FiberAudit::Runtime::Event.new(
      kind: :operation_completed,
      source: :instrumentation,
      occurred_at: Time.utc(2026, 8, 2, 12, 0, 1, 123_456),
      monotonic_ns: 200,
      duration_ns: 50,
      operation: 'Mutex#lock',
      location: FiberAudit::Runtime::Location.new(path: 'app/jobs/task.rb', line: 8, column: 2),
      execution_context: :job,
      thread_id: 4,
      fiber_id: 7,
      measurements: { threshold_ns: 25 }
    )
  end
  let(:summary) do
    FiberAudit::Runtime::SessionSummary.new(
      ended_at: Time.utc(2026, 8, 2, 12, 0, 2),
      ended_monotonic_ns: 300,
      status: :completed,
      events_observed: 2,
      events_emitted: 1,
      sampled_out: 1,
      rate_limited: 0,
      session_event_limited: 0,
      session_byte_limited: 0,
      oversize: 0,
      internal_errors: 0
    )
  end

  it 'uses an independent runtime schema version' do
    expect(described_class::SCHEMA_VERSION).to eq('1.0')
    expect(described_class::SCHEMA_VERSION).to equal(FiberAudit::Runtime::JSONL::Schema::SCHEMA_VERSION)
  end

  it 'builds deterministic session-start records' do
    record = described_class.start_record(session)
    expect(record.keys).to eq(described_class::ENVELOPE_KEYS)
    expect(record['record_type']).to eq('session_start')
    expect(record['sequence']).to eq(0)
    expect(record['recorded_at']).to eq('2026-08-02T12:00:00.000000Z')
    expect(record['payload']['policy']['redaction']).to eq('strict')
  end

  it 'builds event records with privacy-limited scalar data' do
    record = described_class.event_record(session_id: session_id, sequence: 1, event: event)
    expect(record['payload'].keys).to eq(described_class::EVENT_KEYS)
    expect(record['payload']['location']).to eq(
      'path' => 'app/jobs/task.rb', 'line' => 8, 'column' => 2
    )
    expect(record['payload']['measurements']).to eq('threshold_ns' => 25)
  end

  it 'builds session-end records with explicit drop accounting' do
    record = described_class.end_record(session_id: session_id, sequence: 2, summary: summary)
    expect(record['payload']['dropped']).to eq(
      'sampling' => 1,
      'rate_limit' => 0,
      'session_event_limit' => 0,
      'session_byte_limit' => 0,
      'record_size_limit' => 0
    )
  end

  it 'recursively freezes every built record without freezing caller strings' do
    caller_id = session_id.dup
    record = described_class.event_record(session_id: caller_id, sequence: 1, event: event)
    expect(record).to be_frozen
    expect(record['payload']).to be_frozen
    expect(record['payload']['location']).to be_frozen
    expect(record['payload']['measurements']).to be_frozen
    expect(record['session_id']).to be_frozen
    expect(caller_id).not_to be_frozen
  end

  it 'dumps one compact JSON object with exactly one trailing newline' do
    record = described_class.start_record(session)
    output = described_class.dump(record, max_record_bytes: 16_384)
    expect(output.lines.size).to eq(1)
    expect(output).to end_with("\n")
    expect(output).not_to end_with("\n\n")
    expect(JSON.parse(output)).to eq(record)
    expect(output).to be_frozen
  end

  it 'rejects records at the byte boundary plus one' do
    record = described_class.start_record(session)
    output = described_class.dump(record, max_record_bytes: 16_384)
    expect { described_class.dump(record, max_record_bytes: output.bytesize - 1) }
      .to raise_error(FiberAudit::RuntimeSafetyError)
    expect(described_class.dump(record, max_record_bytes: output.bytesize)).to eq(output)
  end

  it 'rejects unknown, missing, and malformed envelope values' do
    record = mutable_copy(described_class.start_record(session))
    expect { described_class.validate!(record.merge('secret' => 'value')) }
      .to raise_error(FiberAudit::RuntimeContractError, /unknown key/)

    record.delete('payload')
    expect { described_class.validate!(record) }
      .to raise_error(FiberAudit::RuntimeContractError, /missing key/)

    invalid = mutable_copy(described_class.start_record(session))
    invalid['recorded_at'] = 'yesterday'
    expect { described_class.validate!(invalid) }
      .to raise_error(FiberAudit::RuntimeContractError, /recorded_at/)
  end

  it 'rejects unknown nested fields and prohibited arbitrary measurement values' do
    record = mutable_copy(described_class.event_record(session_id: session_id, sequence: 1, event: event))
    record['payload']['location']['absolute_path'] = '/secret'
    expect { described_class.validate!(record) }.to raise_error(FiberAudit::RuntimeContractError)

    invalid = mutable_copy(described_class.event_record(session_id: session_id, sequence: 1, event: event))
    invalid['payload']['measurements']['url'] = 'https://secret.example'
    expect { described_class.validate!(invalid) }.to raise_error(FiberAudit::RuntimeContractError)
  end

  it 'matches the versioned three-record JSONL fixture' do
    records = [
      described_class.start_record(session),
      described_class.event_record(session_id: session_id, sequence: 1, event: event),
      described_class.end_record(session_id: session_id, sequence: 2, summary: summary)
    ]
    output = records.map { |record| described_class.dump(record, max_record_bytes: 16_384) }.join
    fixture = File.read(fixtures_path('runtime', 'session_v1.jsonl'))
    expect(output).to eq(fixture)
  end

  def mutable_copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
