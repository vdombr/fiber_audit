# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'FiberAudit runtime foundation loader' do
  it 'loads every public runtime contract independently' do
    script = <<~RUBY
      require 'fiber_audit/runtime'
      constants = [
        FiberAudit::Runtime::Policy,
        FiberAudit::Runtime::Location,
        FiberAudit::Runtime::Event,
        FiberAudit::Runtime::Session,
        FiberAudit::Runtime::SessionSummary,
        FiberAudit::Runtime::Redactor,
        FiberAudit::Runtime::JSONL::Schema,
        FiberAudit::RuntimeContractError,
        FiberAudit::RuntimeSafetyError
      ]
      puts constants.size
    RUBY
    output, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script)
    expect(status).to be_success, stderr
    expect(output.strip).to eq('9')
  end

  it 'does not load static analysis or framework dependencies' do
    script = <<~RUBY
      require 'fiber_audit/runtime'
      prohibited = %w[Prism Rubydex Rails]
      puts prohibited.any? { |name| Object.const_defined?(name, false) }
      puts defined?(FiberAudit::Static).nil?
    RUBY
    output, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script)
    expect(status).to be_success, stderr
    expect(output.lines.map(&:strip)).to eq(%w[false true])
  end
end
