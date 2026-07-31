# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/configuration'
require 'tmpdir'
require 'yaml'

RSpec.describe FiberAudit::Configuration do
  describe 'defaults' do
    subject(:config) { described_class.new }

    it 'uses default static_include patterns' do
      expect(config.static_include).to eq(%w[
                                            app/**/*.rb
                                            lib/**/*.rb
                                            config/**/*.rb
                                            config/initializers/**/*.rb
                                          ])
    end

    it 'uses default static_exclude patterns' do
      expect(config.static_exclude).to eq(%w[
                                            vendor/**/*
                                            tmp/**/*
                                            node_modules/**/*
                                            db/schema.rb
                                          ])
    end

    it 'has empty rules_config' do
      expect(config.rules_config).to eq({})
    end

    it 'defaults report_formats to text' do
      expect(config.report_formats).to eq(%w[text])
    end

    it 'defaults min_severity to :low' do
      expect(config.min_severity).to eq(:low)
    end

    it 'defaults suppressions_path to nil' do
      expect(config.suppressions_path).to be_nil
    end
  end

  describe '.load' do
    it 'returns default configuration when path is nil' do
      config = described_class.load(nil)
      expect(config.static_include).to eq(described_class::DEFAULT_STATIC_INCLUDE)
      expect(config.static_exclude).to eq(described_class::DEFAULT_STATIC_EXCLUDE)
    end

    it 'returns default configuration when file does not exist' do
      config = described_class.load('/nonexistent/path/.fiber-audit.yml')
      expect(config.static_include).to eq(described_class::DEFAULT_STATIC_INCLUDE)
    end

    it 'loads all options from a YAML file' do
      yaml_content = {
        'static' => {
          'include' => ['custom/**/*.rb'],
          'exclude' => ['skip/**/*.rb'],
          'suppressions_path' => '.suppressions.yml'
        },
        'rules' => {
          'FA1001' => { 'enabled' => false },
          'FA1003' => { 'severity' => 'high' }
        },
        'report' => {
          'formats' => %w[text json],
          'min_severity' => 'medium'
        }
      }

      Dir.mktmpdir do |dir|
        path = File.join(dir, '.fiber-audit.yml')
        File.write(path, YAML.dump(yaml_content))

        config = described_class.load(path)

        expect(config.static_include).to eq(['custom/**/*.rb'])
        expect(config.static_exclude).to eq(['skip/**/*.rb'])
        expect(config.suppressions_path).to eq('.suppressions.yml')
        expect(config.rules_config).to eq({
                                            'FA1001' => { 'enabled' => false },
                                            'FA1003' => { 'severity' => 'high' }
                                          })
        expect(config.report_formats).to eq(%w[text json])
        expect(config.min_severity).to eq(:medium)
      end
    end

    it 'falls back to defaults for missing YAML sections' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, '.fiber-audit.yml')
        File.write(path, YAML.dump({}))

        config = described_class.load(path)

        expect(config.static_include).to eq(described_class::DEFAULT_STATIC_INCLUDE)
        expect(config.static_exclude).to eq(described_class::DEFAULT_STATIC_EXCLUDE)
        expect(config.report_formats).to eq(%w[text])
        expect(config.min_severity).to eq(:low)
      end
    end
  end

  describe '#rule_enabled?' do
    subject(:config) do
      described_class.new(rules_config: {
                            'FA1001' => { 'enabled' => false },
                            'FA1002' => { 'enabled' => true }
                          })
    end

    it 'returns false when rule is explicitly disabled' do
      expect(config.rule_enabled?('FA1001')).to be false
    end

    it 'returns true when rule is explicitly enabled' do
      expect(config.rule_enabled?('FA1002')).to be true
    end

    it 'returns true when rule is absent from config' do
      expect(config.rule_enabled?('FA9999')).to be true
    end
  end

  describe '#severity_override' do
    subject(:config) do
      described_class.new(rules_config: {
                            'FA1003' => { 'severity' => 'high' },
                            'FA1001' => { 'enabled' => false }
                          })
    end

    it 'returns overridden severity when set' do
      expect(config.severity_override('FA1003')).to eq(:high)
    end

    it 'returns nil when no severity override is set' do
      expect(config.severity_override('FA1001')).to be_nil
    end

    it 'returns nil for unknown rules' do
      expect(config.severity_override('FA9999')).to be_nil
    end

    it 'raises ArgumentError for invalid severity' do
      config_with_bad = described_class.new(rules_config: {
                                              'FA1005' => { 'severity' => 'bogus' }
                                            })
      expect { config_with_bad.severity_override('FA1005') }.to raise_error(ArgumentError)
    end
  end

  describe 'configuration validation' do
    it 'raises ConfigurationError for invalid static_include type' do
      expect do
        described_class.new(static_include: 'not an array')
      end.to raise_error(FiberAudit::ConfigurationError, /static\.include must be an Array of Strings/)
    end

    it 'raises ConfigurationError for invalid static_include element type' do
      expect do
        described_class.new(static_include: [123, 456])
      end.to raise_error(FiberAudit::ConfigurationError, /static\.include must be an Array of Strings/)
    end

    it 'raises ConfigurationError for invalid static_exclude type' do
      expect do
        described_class.new(static_exclude: { key: 'value' })
      end.to raise_error(FiberAudit::ConfigurationError, /static\.exclude must be an Array of Strings/)
    end

    it 'raises ConfigurationError for invalid rules_config type' do
      expect do
        described_class.new(rules_config: %w[not a hash])
      end.to raise_error(FiberAudit::ConfigurationError, /rules must be a Hash/)
    end

    it 'raises ConfigurationError for invalid report_formats type' do
      expect do
        described_class.new(report_formats: 'text')
      end.to raise_error(FiberAudit::ConfigurationError, /report\.formats must be an Array/)
    end

    it 'passes validation with valid configuration' do
      expect do
        described_class.new(
          static_include: ['app/**/*.rb'],
          static_exclude: ['vendor/**/*'],
          rules_config: { 'FA1001' => { 'enabled' => true } },
          report_formats: %w[text json],
          min_severity: :medium
        )
      end.not_to raise_error
    end
  end
end
