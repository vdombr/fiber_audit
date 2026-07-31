# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FiberAudit::Location do
  subject(:location) { described_class.new(path: 'app/models/user.rb', line: 42, column: 10) }

  describe '#to_h_for_json' do
    it 'returns a hash with path, line, and column' do
      expect(location.to_h_for_json).to eq(
        { path: 'app/models/user.rb', line: 42, column: 10 }
      )
    end
  end

  describe 'immutability' do
    it 'is immutable (Data.define)' do
      expect { location.path = 'other' }.to raise_error(NoMethodError)
    end
  end
end
