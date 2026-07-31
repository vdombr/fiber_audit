# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/configuration'
require 'tmpdir'
require 'yaml'

RSpec.describe FiberAudit::Configuration do
  describe 'standalone loading' do
    it 'can be required independently without the main loader' do
      result = `ruby -Ilib -rfiber_audit/configuration -e "puts FiberAudit::Configuration.new.static_include.first" 2>&1`
      expect($?.success?).to be(true)
      expect(result.strip).to eq('app/**/*.rb')
    end

    it 'explicitly requires errors.rb' do
      result = `ruby -Ilib -rfiber_audit/configuration -e "puts FiberAudit::ConfigurationError" 2>&1`
      expect($?.success?).to be(true)
      expect(result.strip).to eq('FiberAudit::ConfigurationError')
    end

    it 'explicitly requires findings/severity.rb' do
      result = `ruby -Ilib -rfiber_audit/configuration -e "puts FiberAudit::Severity::LEVELS.first" 2>&1`
      expect($?.success?).to be(true)
      expect(result.strip).to eq('critical')
    end
  end

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

    it 'raises ConfigurationError for invalid severity at construction time' do
      expect do
        described_class.new(rules_config: {
                              'FA1005' => { 'severity' => 'bogus' }
                            })
      end.to raise_error(FiberAudit::ConfigurationError, /severity/)
    end
  end

  describe 'strict validation' do
    describe 'unknown keys' do
      it 'raises ConfigurationError for unknown top-level key' do
        yaml_content = {
          'static' => { 'include' => ['app/**/*.rb'] },
          'unknown_key' => 'value'
        }

        Dir.mktmpdir do |dir|
          path = File.join(dir, '.fiber-audit.yml')
          File.write(path, YAML.dump(yaml_content))

          expect do
            described_class.load(path)
          end.to raise_error(FiberAudit::ConfigurationError, /unknown configuration key 'unknown_key' at top level/)
        end
      end

      it 'raises ConfigurationError for unknown static key' do
        yaml_content = {
          'static' => { 'include' => ['app/**/*.rb'], 'bad_key' => 'value' }
        }

        Dir.mktmpdir do |dir|
          path = File.join(dir, '.fiber-audit.yml')
          File.write(path, YAML.dump(yaml_content))

          expect do
            described_class.load(path)
          end.to raise_error(FiberAudit::ConfigurationError, /unknown configuration key 'bad_key' at static/)
        end
      end

      it 'raises ConfigurationError for unknown report key' do
        yaml_content = {
          'report' => { 'formats' => ['text'], 'extra' => 'value' }
        }

        Dir.mktmpdir do |dir|
          path = File.join(dir, '.fiber-audit.yml')
          File.write(path, YAML.dump(yaml_content))

          expect do
            described_class.load(path)
          end.to raise_error(FiberAudit::ConfigurationError, /unknown configuration key 'extra' at report/)
        end
      end

      it 'raises ConfigurationError for unknown rule entry key' do
        yaml_content = {
          'rules' => { 'FA1001' => { 'enabled' => true, 'unknown' => 'value' } }
        }

        Dir.mktmpdir do |dir|
          path = File.join(dir, '.fiber-audit.yml')
          File.write(path, YAML.dump(yaml_content))

          expect do
            described_class.load(path)
          end.to raise_error(FiberAudit::ConfigurationError, /unknown configuration key 'unknown' in rules\.FA1001/)
        end
      end
    end

    describe 'YAML structure validation' do
      it 'raises ConfigurationError when top-level YAML is not a hash' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, '.fiber-audit.yml')
          File.write(path, YAML.dump('just a string'))

          expect do
            described_class.load(path)
          end.to raise_error(FiberAudit::ConfigurationError, /configuration must be a YAML mapping/)
        end
      end

      it 'raises ConfigurationError when static section is not a hash' do
        yaml_content = { 'static' => 'not a hash' }

        Dir.mktmpdir do |dir|
          path = File.join(dir, '.fiber-audit.yml')
          File.write(path, YAML.dump(yaml_content))

          expect do
            described_class.load(path)
          end.to raise_error(FiberAudit::ConfigurationError, /static must be a mapping/)
        end
      end

      it 'raises ConfigurationError when report section is not a hash' do
        yaml_content = { 'report' => ['array', 'not', 'hash'] }

        Dir.mktmpdir do |dir|
          path = File.join(dir, '.fiber-audit.yml')
          File.write(path, YAML.dump(yaml_content))

          expect do
            described_class.load(path)
          end.to raise_error(FiberAudit::ConfigurationError, /report must be a mapping/)
        end
      end

      it 'raises ConfigurationError when rules section is not a hash' do
        yaml_content = { 'rules' => 'not a hash' }

        Dir.mktmpdir do |dir|
          path = File.join(dir, '.fiber-audit.yml')
          File.write(path, YAML.dump(yaml_content))

          expect do
            described_class.load(path)
          end.to raise_error(FiberAudit::ConfigurationError, /rules must be a mapping/)
        end
      end
    end

    describe 'report formats validation' do
      it 'raises ConfigurationError when report_formats is empty' do
        expect do
          described_class.new(report_formats: [])
        end.to raise_error(FiberAudit::ConfigurationError, /report\.formats must be a non-empty Array/)
      end

      it 'raises ConfigurationError when report_formats contains invalid format' do
        expect do
          described_class.new(report_formats: %w[text xml])
        end.to raise_error(FiberAudit::ConfigurationError, /report\.formats must be a non-empty Array/)
      end

      it 'accepts valid formats (text and json)' do
        expect do
          described_class.new(report_formats: %w[text json])
        end.not_to raise_error
      end

      it 'accepts single valid format' do
        expect do
          described_class.new(report_formats: ['json'])
        end.not_to raise_error
      end
    end

    describe 'min_severity validation' do
      it 'raises ConfigurationError for invalid min_severity' do
        expect do
          described_class.new(min_severity: :bogus)
        end.to raise_error(FiberAudit::ConfigurationError, /report\.min_severity is not a valid severity/)
      end

      it 'wraps Severity.coerce ArgumentError as ConfigurationError' do
        expect do
          described_class.new(min_severity: 'invalid')
        end.to raise_error(FiberAudit::ConfigurationError)
      end

      it 'accepts valid severity levels' do
        %i[critical high medium low info].each do |severity|
          expect do
            described_class.new(min_severity: severity)
          end.not_to raise_error
        end
      end
    end

    describe 'suppressions_path validation' do
      it 'raises ConfigurationError when suppressions_path is not nil or string' do
        expect do
          described_class.new(suppressions_path: 123)
        end.to raise_error(FiberAudit::ConfigurationError, /static\.suppressions_path must be nil or a String/)
      end

      it 'accepts nil suppressions_path' do
        expect do
          described_class.new(suppressions_path: nil)
        end.not_to raise_error
      end

      it 'accepts string suppressions_path' do
        expect do
          described_class.new(suppressions_path: '.suppressions.yml')
        end.not_to raise_error
      end
    end

    describe 'rule entry validation' do
      it 'raises ConfigurationError when rule entry is not a hash' do
        expect do
          described_class.new(rules_config: { 'FA1001' => 'not a hash' })
        end.to raise_error(FiberAudit::ConfigurationError, /rules\.FA1001 must be a Hash/)
      end

      it 'raises ConfigurationError when enabled is not a boolean' do
        expect do
          described_class.new(rules_config: { 'FA1001' => { 'enabled' => 'yes' } })
        end.to raise_error(FiberAudit::ConfigurationError, /rules\.FA1001\.enabled must be a Boolean/)
      end

      it 'raises ConfigurationError when severity in rule entry is invalid' do
        expect do
          described_class.new(rules_config: { 'FA1001' => { 'severity' => 'bogus' } })
        end.to raise_error(FiberAudit::ConfigurationError, /rules\.FA1001\.severity is not a valid severity/)
      end

      it 'accepts valid rule entries' do
        expect do
          described_class.new(rules_config: {
            'FA1001' => { 'enabled' => true, 'severity' => 'high' },
            'FA1002' => { 'enabled' => false }
          })
        end.not_to raise_error
      end
    end

    describe 'raw Severity.coerce behavior' do
      it 'does not modify raw Severity.coerce to raise ConfigurationError' do
        expect do
          FiberAudit::Severity.coerce(:bogus)
        end.to raise_error(ArgumentError)
      end

      it 'still raises ArgumentError for invalid severity' do
        expect do
          FiberAudit::Severity.coerce('invalid')
        end.to raise_error(ArgumentError, /unknown severity/)
      end
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
