# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/call_site'

RSpec.describe FiberAudit::Static::CallSite do
  describe 'Data contract' do
    it 'defines exactly 13 fields' do
      expect(described_class.members).to eq(
        %i[
          path line column
          receiver_source receiver_constant method_name
          arguments enclosing_symbol nesting
          execution_context resolution confidence
        ]
      )
    end
  end

  describe '#initialize' do
    it 'normalizes method_name from String to Symbol' do
      cs = described_class.new(
        path: 'test.rb', line: 1, column: 0,
        receiver_source: 'Open3', receiver_constant: 'Open3', method_name: 'capture3',
        arguments: [], enclosing_symbol: nil, nesting: [],
        execution_context: nil, resolution: 'Open3.capture3', confidence: :high
      )

      expect(cs.method_name).to eq(:capture3)
      expect(cs.method_name).to be_a(Symbol)
    end

    it 'accepts method_name as Symbol directly' do
      cs = described_class.new(
        path: 'test.rb', line: 1, column: 0,
        receiver_source: nil, receiver_constant: nil, method_name: :puts,
        arguments: [], enclosing_symbol: nil, nesting: [],
        execution_context: nil, resolution: nil, confidence: :unknown
      )

      expect(cs.method_name).to eq(:puts)
      expect(cs.method_name).to be_a(Symbol)
    end
  end

  describe '#location' do
    it 'returns a Location object with path, line, column' do
      cs = described_class.new(
        path: 'app/models/user.rb', line: 42, column: 4,
        receiver_source: 'Open3', receiver_constant: 'Open3', method_name: :capture3,
        arguments: ['cmd'], enclosing_symbol: 'User#run', nesting: ['User'],
        execution_context: nil, resolution: 'Open3.capture3', confidence: :high
      )

      location = cs.location
      expect(location).to be_a(FiberAudit::Location)
      expect(location.path).to eq('app/models/user.rb')
      expect(location.line).to eq(42)
      expect(location.column).to eq(4)
    end
  end

  describe '#method_name_sym' do
    it 'returns the method_name as Symbol' do
      cs = described_class.new(
        path: 'test.rb', line: 1, column: 0,
        receiver_source: nil, receiver_constant: nil, method_name: :get,
        arguments: [], enclosing_symbol: nil, nesting: [],
        execution_context: nil, resolution: nil, confidence: :unknown
      )

      expect(cs.method_name_sym).to eq(:get)
      expect(cs.method_name_sym).to be_a(Symbol)
    end

    it 'is identical to method_name' do
      cs = described_class.new(
        path: 'test.rb', line: 1, column: 0,
        receiver_source: 'Thread', receiver_constant: 'Thread', method_name: :new,
        arguments: [], enclosing_symbol: nil, nesting: [],
        execution_context: nil, resolution: 'Thread.new', confidence: :high
      )

      expect(cs.method_name_sym).to eq(cs.method_name)
    end
  end

  describe 'immutability' do
    it 'creates immutable data objects' do
      cs = described_class.new(
        path: 'test.rb', line: 1, column: 0,
        receiver_source: nil, receiver_constant: nil, method_name: :test,
        arguments: [], enclosing_symbol: nil, nesting: [],
        execution_context: nil, resolution: nil, confidence: :unknown
      )

      expect { cs.path = 'other.rb' }.to raise_error(NoMethodError)
    end
  end

  describe 'field values' do
    it 'stores all fields exactly as provided' do
      cs = described_class.new(
        path: 'lib/worker.rb',
        line: 15,
        column: 8,
        receiver_source: 'Redis',
        receiver_constant: 'Redis',
        method_name: :get,
        arguments: ['"key"'],
        enclosing_symbol: 'Worker#process',
        nesting: ['Worker'],
        execution_context: :job,
        resolution: 'Redis.get',
        confidence: :high
      )

      expect(cs.path).to eq('lib/worker.rb')
      expect(cs.line).to eq(15)
      expect(cs.column).to eq(8)
      expect(cs.receiver_source).to eq('Redis')
      expect(cs.receiver_constant).to eq('Redis')
      expect(cs.method_name).to eq(:get)
      expect(cs.arguments).to eq(['"key"'])
      expect(cs.enclosing_symbol).to eq('Worker#process')
      expect(cs.nesting).to eq(['Worker'])
      expect(cs.execution_context).to eq(:job)
      expect(cs.resolution).to eq('Redis.get')
      expect(cs.confidence).to eq(:high)
    end

    it 'allows nil for optional fields' do
      cs = described_class.new(
        path: 'test.rb', line: 1, column: 0,
        receiver_source: nil, receiver_constant: nil, method_name: :puts,
        arguments: [], enclosing_symbol: nil, nesting: [],
        execution_context: nil, resolution: nil, confidence: :unknown
      )

      expect(cs.receiver_source).to be_nil
      expect(cs.receiver_constant).to be_nil
      expect(cs.enclosing_symbol).to be_nil
      expect(cs.execution_context).to be_nil
      expect(cs.resolution).to be_nil
    end
  end
end
