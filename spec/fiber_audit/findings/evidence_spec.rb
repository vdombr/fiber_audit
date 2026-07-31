# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FiberAudit::Evidence do
  describe 'construction' do
    it 'requires source and message' do
      evidence = described_class.new(source: :parser, message: 'blocking call found')
      expect(evidence.source).to eq(:parser)
      expect(evidence.message).to eq('blocking call found')
    end

    it 'defaults details to an empty hash' do
      evidence = described_class.new(source: :parser, message: 'test')
      expect(evidence.details).to eq({})
    end

    it 'accepts explicit details' do
      details = { method: 'IO.read', arity: 1 }
      evidence = described_class.new(source: :scheduler, message: 'blocked', details: details)
      expect(evidence.details).to eq(details)
    end

    it 'normalizes nil details to empty hash' do
      evidence = described_class.new(source: :parser, message: 'test', details: nil)
      expect(evidence.details).to eq({})
    end
  end

  describe '#to_h_for_json' do
    it 'returns a hash with source, message, and details' do
      evidence = described_class.new(source: :parser, message: 'blocked', details: { key: 'val' })
      expect(evidence.to_h_for_json).to eq(
        { source: :parser, message: 'blocked', details: { key: 'val' } }
      )
    end

    it 'includes empty details when none provided' do
      evidence = described_class.new(source: :parser, message: 'blocked')
      expect(evidence.to_h_for_json).to eq(
        { source: :parser, message: 'blocked', details: {} }
      )
    end
  end
end
