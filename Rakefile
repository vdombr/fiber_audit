# frozen_string_literal: true

require 'rspec/core/rake_task'
require_relative 'lib/fiber_audit/version'

RSpec::Core::RakeTask.new(:spec)
task default: :spec

namespace :release do
  desc 'Verify gem builds and contains expected files'
  task :sanity do
    sh 'gem build fiber_audit.gemspec'
    sh "gem specification fiber_audit-#{FiberAudit::VERSION}.gem files --yaml"
  end
end
