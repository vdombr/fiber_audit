# frozen_string_literal: true

require 'yaml'
require 'pathname'

module FiberAudit
  class ConfigurationError < StandardError; end

  class Configuration
    DEFAULT_STATIC_INCLUDE = %w[
      app/**/*.rb
      lib/**/*.rb
      config/**/*.rb
      config/initializers/**/*.rb
    ].freeze

    DEFAULT_STATIC_EXCLUDE = %w[
      vendor/**/*
      tmp/**/*
      node_modules/**/*
      db/schema.rb
    ].freeze

    attr_reader :static_include, :static_exclude, :rules_config,
                :report_formats, :min_severity, :suppressions_path

    def initialize(
      static_include: DEFAULT_STATIC_INCLUDE,
      static_exclude: DEFAULT_STATIC_EXCLUDE,
      rules_config: {},
      report_formats: %w[text],
      min_severity: :low,
      suppressions_path: nil
    )
      validate_config_types!(static_include, static_exclude, rules_config, report_formats, min_severity)

      @static_include = static_include
      @static_exclude = static_exclude
      @rules_config = rules_config
      @report_formats = report_formats
      @min_severity = Severity.coerce(min_severity)
      @suppressions_path = suppressions_path
    end

    private

    def validate_config_types!(include, exclude, rules, formats, _severity)
      unless include.is_a?(Array) && include.all?(String)
        raise ConfigurationError, 'static.include must be an Array of Strings'
      end
      unless exclude.is_a?(Array) && exclude.all?(String)
        raise ConfigurationError, 'static.exclude must be an Array of Strings'
      end
      raise ConfigurationError, 'rules must be a Hash' unless rules.is_a?(Hash)
      return if formats.is_a?(Array)

      raise ConfigurationError, 'report.formats must be an Array'

      # severity is validated by Severity.coerce
    end

    public

    def self.load(path = nil)
      return new unless path && File.exist?(path)

      yaml = YAML.safe_load_file(path) || {}
      static = yaml['static'] || {}
      rules = yaml['rules'] || {}
      report = yaml['report'] || {}

      new(
        static_include: static['include'] || DEFAULT_STATIC_INCLUDE,
        static_exclude: static['exclude'] || DEFAULT_STATIC_EXCLUDE,
        rules_config: rules,
        report_formats: report['formats'] || %w[text],
        min_severity: report['min_severity']&.to_sym || :low,
        suppressions_path: static['suppressions_path']
      )
    end

    def rule_enabled?(rule_id)
      entry = @rules_config[rule_id] || {}
      entry.fetch('enabled', true)
    end

    def severity_override(rule_id)
      entry = @rules_config[rule_id] || {}
      sev = entry['severity']
      sev ? Severity.coerce(sev.to_sym) : nil
    end
  end
end
