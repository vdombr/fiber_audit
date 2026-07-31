# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FiberAudit::Static::SemanticIndex do
  let(:fixture_root) { File.expand_path('../../fixtures/rubydex_spike', __dir__) }

  describe '#build' do
    it 'indexes the workspace' do
      index = described_class.new(root: fixture_root).build
      expect(index.declarations).not_to be_empty
    end

    it 'works with relative paths' do
      relative_root = 'spec/fixtures/rubydex_spike'
      index = described_class.new(root: relative_root).build
      expect(index.declarations).not_to be_empty
    end

    it 'works with absolute paths' do
      absolute_root = File.expand_path('spec/fixtures/rubydex_spike')
      index = described_class.new(root: absolute_root).build
      expect(index.declarations).not_to be_empty
    end

    it 'produces identical results for relative and absolute paths' do
      relative_index = described_class.new(root: 'spec/fixtures/rubydex_spike').build
      absolute_index = described_class.new(root: File.expand_path('spec/fixtures/rubydex_spike')).build
      expect(relative_index.declarations.size).to eq(absolute_index.declarations.size)
    end
  end

  describe '#resolve_constant' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'resolves existing constants' do
      result = index.resolve_constant('SimpleClass', nesting: [])
      expect(result).not_to be_nil
      expect(result.name).to eq('SimpleClass')
    end

    it 'returns nil for non-existent constants' do
      result = index.resolve_constant('NonExistent', nesting: [])
      expect(result).to be_nil
    end
  end

  describe '#descendants_of' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'returns descendants' do
      descendants = index.descendants_of('ApplicationController')
      expect(descendants).to include('UsersController')
    end
  end

  describe '#ancestors_of' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'returns ancestors' do
      ancestors = index.ancestors_of('UsersController')
      expect(ancestors).to include('ApplicationController')
    end
  end

  describe '#references_to' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'returns references to constants' do
      # ApplicationController is referenced in controller_inheritance.rb as a superclass
      refs = index.references_to('ApplicationController')
      expect(refs).not_to be_empty
      expect(refs.first[:name]).to eq('ApplicationController')
    end

    it 'returns empty array for constants with no references' do
      # SimpleClass is only declared, never referenced elsewhere
      refs = index.references_to('SimpleClass')
      expect(refs).to be_empty
    end
  end

  describe '#gaps' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'records Rubydex gaps' do
      expect(index.gaps).not_to be_empty
      expect(index.gaps.map { |g| g[:method] }).to include('method_name_from_reference')
    end

    it 'is idempotent' do
      gaps_before = index.gaps.dup
      index.send(:record_gaps)
      expect(index.gaps).to eq(gaps_before)
    end
  end
end
