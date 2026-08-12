# frozen_string_literal: true

require_relative 'lib/fiber_audit/version'

Gem::Specification.new do |spec|
  spec.name          = 'fiber_audit'
  spec.version       = FiberAudit::VERSION
  spec.authors       = ['FiberAudit Contributors']
  spec.summary       = 'Static and observational runtime fiber-scheduler auditor for Ruby and Rails'
  spec.homepage      = 'https://github.com/vdombr/fiber_audit'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    'lib/**/*.rb',
    'bin/*',
    'README.md',
    'ARCHITECTURE.md',
    'CHANGELOG.md',
    'LICENSE',
    '.fiber-audit.example.yml'
  ]
  spec.bindir        = 'bin'
  spec.executables   = ['fiber-audit']

  # Runtime dependencies
  spec.add_dependency 'prism'
  spec.add_dependency 'rubydex', '~> 0.2.0'

  # Development dependencies moved to Gemfile to resolve Gemspec/DevelopmentDependencies
end
