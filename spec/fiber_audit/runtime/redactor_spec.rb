# frozen_string_literal: true

require 'fiber_audit/runtime/redactor'

RSpec.describe FiberAudit::Runtime::Redactor do
  let(:root) { File.expand_path('../../../fixtures/apps/poro_clean', __dir__) }
  subject(:redactor) { described_class.new(root: root) }

  it 'is immutable and uses strict policy' do
    expect(redactor).to be_frozen
    expect(redactor.policy).to be_strict_redaction
  end

  it 'converts absolute paths inside the root to project-relative locations' do
    path = File.join(root, 'lib', 'clean_service.rb')
    location = redactor.location(path: path, line: 2, column: 4)
    expect(location.to_h).to eq(path: 'lib/clean_service.rb', line: 2, column: 4)
  end

  it 'preserves safe relative paths and normalizes separators' do
    expect(redactor.location(path: 'app\\jobs/task.rb').path).to eq('app/jobs/task.rb')
  end

  it 'marks external and escaping paths without leaking them' do
    expect(redactor.location(path: File.expand_path('/tmp/secret.rb')).path).to eq('[external]')
    expect(redactor.location(path: '../../secret.rb').path).to eq('[external]')
    expect(redactor.location(path: 'C:\\secrets\\key.rb').path).to eq('[external]')
  end

  it 'handles Windows roots and paths lexically without filesystem access' do
    windows = described_class.new(root: 'C:\\Project')
    expect(windows.location(path: 'c:\\project\\app\\job.rb').path).to eq('app/job.rb')
    expect(windows.location(path: 'D:\\secret.rb').path).to eq('[external]')
  end

  it 'redacts malformed paths and drops coordinates when validation fails' do
    location = redactor.location(path: "secret\n.rb", line: 4, column: 2)
    expect(location.to_h).to eq(path: '[redacted]', line: 4, column: 2)

    invalid_coordinate = redactor.location(path: 'app/a.rb', line: 0, column: 2)
    expect(invalid_coordinate.to_h).to eq(path: '[redacted]', line: nil, column: nil)
  end

  it 'preserves canonical technical operations' do
    expect(redactor.operation('Net::HTTP.get')).to eq('Net::HTTP.get')
    expect(redactor.operation(:'Mutex#lock')).to eq('Mutex#lock')
    expect(redactor.operation('Thread.current')).to eq('Thread.current')
    expect(redactor.operation('Thread#[]=')).to eq('Thread#[]=')
  end

  it 'redacts URLs, arguments, whitespace payloads, controls, and arbitrary objects' do
    values = [
      'https://secret.example',
      'Net::HTTP.get(secret)',
      'Kernel.system rm -rf',
      "Mutex#lock\nsecret",
      Object.new
    ]
    expect(values.map { |value| redactor.operation(value) }).to all(eq('[redacted]'))
  end

  it 'produces redacted operations accepted by the event contract' do
    operation = redactor.operation('https://secret.example')
    event = FiberAudit::Runtime::Event.new(
      kind: :operation_completed,
      source: :instrumentation,
      occurred_at: Time.now,
      monotonic_ns: 1,
      operation: operation
    )
    expect(event.operation).to eq('[redacted]')
  end

  it 'preserves nil operations' do
    expect(redactor.operation(nil)).to be_nil
  end
end
