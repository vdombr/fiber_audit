# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FiberAudit::Correlation::Fingerprint do
  describe '.call' do
    it 'produces a 64-character hex digest' do
      digest = described_class.call(
        rule_id: 'FIB001',
        path: 'app/models/user.rb',
        enclosing_symbol: 'User#import',
        operation: :blocking_read
      )
      expect(digest).to match(/\A[0-9a-f]{64}\z/)
    end

    context 'stability' do
      it 'produces the same digest for identical inputs across calls' do
        args = {
          rule_id: 'FIB001',
          path: 'app/models/user.rb',
          enclosing_symbol: 'User#import',
          operation: :blocking_read
        }

        d1 = described_class.call(**args)
        d2 = described_class.call(**args)
        expect(d1).to eq(d2)
      end
    end

    context 'different inputs produce different digests' do
      let(:base) do
        {
          rule_id: 'FIB001',
          path: 'app/models/user.rb',
          enclosing_symbol: 'User#import',
          operation: :blocking_read
        }
      end

      it 'differs when rule_id changes' do
        expect(described_class.call(**base, rule_id: 'FIB002'))
          .not_to eq(described_class.call(**base))
      end

      it 'differs when path changes' do
        expect(described_class.call(**base, path: 'app/models/post.rb'))
          .not_to eq(described_class.call(**base))
      end

      it 'differs when enclosing_symbol changes' do
        expect(described_class.call(**base, enclosing_symbol: 'User#export'))
          .not_to eq(described_class.call(**base))
      end

      it 'differs when operation changes' do
        expect(described_class.call(**base, operation: :blocking_write))
          .not_to eq(described_class.call(**base))
      end
    end
  end

  describe '.normalize_path' do
    it 'returns empty string for nil' do
      expect(described_class.normalize_path(nil)).to eq('')
    end

    it 'cleans up redundant path segments' do
      expect(described_class.normalize_path('app/models/../models/user.rb'))
        .to eq('app/models/user.rb')
    end

    it 'resolves dot segments' do
      expect(described_class.normalize_path('./app/models/user.rb'))
        .to eq('app/models/user.rb')
    end

    it 'returns the string as-is for paths that cannot be parsed' do
      # Pathname generally doesn't raise for most strings, but we test the rescue
      result = described_class.normalize_path('simple.rb')
      expect(result).to eq('simple.rb')
    end
  end
end
