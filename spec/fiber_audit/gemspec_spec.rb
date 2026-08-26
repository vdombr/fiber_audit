# frozen_string_literal: true

require 'spec_helper'
require 'rubygems'

RSpec.describe 'fiber_audit.gemspec' do
  let(:specification) { Gem::Specification.load(File.expand_path('../../fiber_audit.gemspec', __dir__)) }

  it 'ships the root documentation and maintainer guide' do
    expect(specification.files).to include('README.md', 'ARCHITECTURE.md', 'CHANGELOG.md', 'doc/maintainer-validation.md')
  end

  it 'ships every regular documentation file' do
    expected = Dir['doc/**/*'].select { |path| File.file?(path) }.sort

    expect(specification.files).to include(*expected)
  end
end
