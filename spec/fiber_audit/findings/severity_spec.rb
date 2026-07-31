# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FiberAudit::Severity do
  describe '.coerce' do
    it 'returns the value when it is a valid severity level' do
      described_class::LEVELS.each do |level|
        expect(described_class.coerce(level)).to eq(level)
      end
    end

    it 'raises ArgumentError for an unknown severity' do
      expect { described_class.coerce(:panic) }.to raise_error(ArgumentError, /unknown severity/)
    end

    it 'raises ArgumentError for a string value' do
      expect { described_class.coerce('high') }.to raise_error(ArgumentError)
    end
  end

  describe '.index' do
    it 'returns 0 for :critical' do
      expect(described_class.index(:critical)).to eq(0)
    end

    it 'returns 1 for :high' do
      expect(described_class.index(:high)).to eq(1)
    end

    it 'returns 2 for :medium' do
      expect(described_class.index(:medium)).to eq(2)
    end

    it 'returns 3 for :low' do
      expect(described_class.index(:low)).to eq(3)
    end

    it 'returns 4 for :info' do
      expect(described_class.index(:info)).to eq(4)
    end

    it 'orders critical before high' do
      expect(described_class.index(:critical)).to be < described_class.index(:high)
    end

    it 'orders low before info' do
      expect(described_class.index(:low)).to be < described_class.index(:info)
    end

    it 'returns LEVELS.size for an unknown severity' do
      expect(described_class.index(:bogus)).to eq(described_class::LEVELS.size)
    end
  end
end
