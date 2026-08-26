# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubygems/package'
require_relative 'lib/fiber_audit/version'

RSpec::Core::RakeTask.new(:spec)
task default: :spec

namespace :release do
  desc 'Verify gem builds and contains expected files'
  task :sanity do
    sh 'gem build fiber_audit.gemspec'
    gem_path = "fiber_audit-#{FiberAudit::VERSION}.gem"
    expected_docs = Dir['doc/**/*'].select { |path| File.file?(path) }.sort
    packaged_docs = Gem::Package.new(gem_path).spec.files.grep(%r{\Adoc/}).sort
    missing_docs = expected_docs - packaged_docs
    abort("Missing doc files from gem: #{missing_docs.join(', ')}") unless missing_docs.empty?
    sh "gem specification #{gem_path} files --yaml"
  end
end
