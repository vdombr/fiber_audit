# frozen_string_literal: true

require_relative 'lib/fiber_audit/version'

Gem::Specification.new do |spec|
  spec.name          = 'fiber_audit'
  spec.version       = FiberAudit::VERSION
  spec.authors       = ['FiberAudit Contributors']
  spec.summary       = 'Static and runtime fiber-scheduler compatibility auditor for Ruby/Rails applications'
  spec.homepage      = 'https://github.com/fiber-audit/fiber_audit'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.2.0'

  spec.files         = Dir['lib/**/*.rb', 'bin/*', 'README.md', 'CHANGELOG.md', '.fiber-audit.example.yml']
  spec.bindir        = 'bin'
  spec.executables   = ['fiber-audit']

  # Runtime dependencies
  spec.add_dependency 'prism'
  spec.add_dependency 'rubydex', '~> 0.2.0'

  # Development dependencies
  spec.add_development_dependency 'rake',    '~> 13.0'
  spec.add_development_dependency 'rspec',   '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.50'
end
