# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/fiber_context'

RSpec.describe FiberAudit::Static::FiberContext do
  it 'is immutable and maps canonical operations' do
    context = described_class.new(kind: :fiber_new, line: 4, column: 2)
    expect(context.members).to eq(%i[kind line column])
    expect(context.operation).to eq('Fiber.new(blocking: true)')
    expect(context).to be_frozen
    expect(described_class.new(kind: 'fiber_blocking', line: 1, column: 0).operation).to eq('Fiber.blocking')
  end

  it 'validates kind and coordinates' do
    expect { described_class.new(kind: :unknown, line: 1, column: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(kind: :fiber_new, line: 0, column: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(kind: :fiber_new, line: 1, column: -1) }.to raise_error(ArgumentError)
  end

  it 'matches originating coordinates' do
    context = described_class.new(kind: :fiber_new, line: 4, column: 2)
    expect(context.starts_at?(Struct.new(:line, :column).new(4, 2))).to be(true)
    expect(context.starts_at?(Struct.new(:line, :column).new(5, 2))).to be(false)
  end
end
