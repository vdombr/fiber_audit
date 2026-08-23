# frozen_string_literal: true

require 'yaml'
require 'pathname'
require_relative 'errors'
require_relative 'findings/severity'
require_relative 'runtime/policy'
require_relative 'runtime/watchdog_policy'
require_relative 'runtime/operation_liveness_policy'

module FiberAudit
  # rubocop:disable Metrics/ClassLength
  class Configuration
    KNOWN_TOP_LEVEL_KEYS = %w[static rules report runtime].freeze
    KNOWN_STATIC_KEYS = %w[include exclude suppressions_path].freeze
    KNOWN_REPORT_KEYS = %w[formats min_severity].freeze
    KNOWN_RULE_KEYS = %w[enabled severity].freeze
    KNOWN_RUNTIME_KEYS = %w[redaction sampling overhead watchdog operation_liveness fail_open].freeze
    KNOWN_OPERATION_LIVENESS_KEYS = %w[enabled poll_interval_ms long_active_threshold_ms].freeze
    KNOWN_REDACTION_KEYS = %w[mode].freeze
    KNOWN_SAMPLING_KEYS = %w[rate].freeze
    KNOWN_OVERHEAD_KEYS = %w[
      max_events_per_second max_events_per_session max_record_bytes max_session_bytes
    ].freeze
    KNOWN_WATCHDOG_KEYS = %w[
      enabled heartbeat_interval_ms stall_threshold_ms max_frames
    ].freeze
    RUNTIME_POLICY_PATHS = {
      'redaction' => 'runtime.redaction.mode',
      'sampling_rate' => 'runtime.sampling.rate',
      'max_events_per_second' => 'runtime.overhead.max_events_per_second',
      'max_events_per_session' => 'runtime.overhead.max_events_per_session',
      'max_record_bytes' => 'runtime.overhead.max_record_bytes',
      'max_session_bytes' => 'runtime.overhead.max_session_bytes',
      'fail_open' => 'runtime.fail_open'
    }.freeze
    VALID_FORMATS = %w[text json].freeze

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
                :report_formats, :min_severity, :suppressions_path,
                :runtime_policy, :runtime_watchdog_policy,
                :runtime_operation_liveness_policy

    def initialize(
      static_include: DEFAULT_STATIC_INCLUDE,
      static_exclude: DEFAULT_STATIC_EXCLUDE,
      rules_config: {},
      report_formats: %w[text],
      min_severity: :low,
      suppressions_path: nil,
      runtime_policy: Runtime::Policy.new,
      runtime_watchdog_policy: Runtime::WatchdogPolicy.new,
      runtime_operation_liveness_policy: Runtime::OperationLivenessPolicy.new
    )
      validate_types!(
        static_include, static_exclude, rules_config,
        report_formats, min_severity, suppressions_path, runtime_policy,
        runtime_watchdog_policy, runtime_operation_liveness_policy
      )

      @static_include = static_include
      @static_exclude = static_exclude
      @rules_config = rules_config
      @report_formats = report_formats
      @min_severity = coerce_severity(min_severity, 'report.min_severity')
      @suppressions_path = suppressions_path
      @runtime_policy = runtime_policy
      @runtime_watchdog_policy = runtime_watchdog_policy
      @runtime_operation_liveness_policy = runtime_operation_liveness_policy
    end

    def rule_enabled?(rule_id)
      entry = @rules_config[rule_id] || {}
      entry.fetch('enabled', true)
    end

    # Returns the overridden severity for a rule as a validated Symbol,
    # or nil when no override is configured.
    def severity_override(rule_id)
      entry = @rules_config[rule_id] || {}
      sev = entry['severity']
      return nil unless sev

      coerce_severity(sev, "rules.#{rule_id}.severity")
    end

    class << self
      def load(path = nil)
        return new unless path && File.exist?(path)

        yaml = YAML.safe_load_file(path) || {}
        validate_yaml_structure!(yaml)

        static = yaml['static'] || {}
        rules = yaml['rules'] || {}
        report = yaml['report'] || {}
        runtime = yaml['runtime'] || {}

        new(
          static_include: static['include'] || DEFAULT_STATIC_INCLUDE,
          static_exclude: static['exclude'] || DEFAULT_STATIC_EXCLUDE,
          rules_config: rules,
          report_formats: report['formats'] || %w[text],
          min_severity: report.fetch('min_severity', :low),
          suppressions_path: static['suppressions_path'],
          runtime_policy: runtime_policy_from(runtime),
          runtime_watchdog_policy: runtime_watchdog_policy_from(runtime),
          runtime_operation_liveness_policy: runtime_operation_liveness_policy_from(runtime)
        )
      end

      private

      def validate_yaml_structure!(yaml)
        unless yaml.is_a?(Hash)
          raise ConfigurationError,
                "configuration must be a YAML mapping, got #{yaml.class}"
        end

        check_unknown_keys(yaml, KNOWN_TOP_LEVEL_KEYS, 'top level')

        if yaml.key?('static')
          static = yaml['static']
          unless static.is_a?(Hash)
            raise ConfigurationError,
                  "static must be a mapping, got #{static.class}"
          end
          check_unknown_keys(static, KNOWN_STATIC_KEYS, 'static')
        end

        if yaml.key?('report')
          report = yaml['report']
          unless report.is_a?(Hash)
            raise ConfigurationError,
                  "report must be a mapping, got #{report.class}"
          end
          check_unknown_keys(report, KNOWN_REPORT_KEYS, 'report')
        end

        validate_runtime_structure!(yaml['runtime']) if yaml.key?('runtime')

        return unless yaml.key?('rules')

        rules = yaml['rules']
        return if rules.is_a?(Hash)

        raise ConfigurationError,
              "rules must be a mapping, got #{rules.class}"
      end

      def validate_runtime_structure!(runtime)
        unless runtime.is_a?(Hash)
          raise ConfigurationError,
                "runtime must be a mapping, got #{runtime.class}"
        end
        check_unknown_keys(runtime, KNOWN_RUNTIME_KEYS, 'runtime')
        validate_runtime_mapping!(runtime, 'redaction', KNOWN_REDACTION_KEYS)
        validate_runtime_mapping!(runtime, 'sampling', KNOWN_SAMPLING_KEYS)
        validate_runtime_mapping!(runtime, 'overhead', KNOWN_OVERHEAD_KEYS)
        validate_runtime_mapping!(runtime, 'watchdog', KNOWN_WATCHDOG_KEYS)
        validate_runtime_mapping!(runtime, 'operation_liveness', KNOWN_OPERATION_LIVENESS_KEYS)
      end

      def validate_runtime_mapping!(runtime, key, allowed)
        return unless runtime.key?(key)

        value = runtime[key]
        unless value.is_a?(Hash)
          raise ConfigurationError,
                "runtime.#{key} must be a mapping, got #{value.class}"
        end
        check_unknown_keys(value, allowed, "runtime.#{key}")
      end

      def runtime_policy_from(runtime)
        defaults = Runtime::Policy::DEFAULTS
        redaction = runtime.fetch('redaction', {})
        sampling = runtime.fetch('sampling', {})
        overhead = runtime.fetch('overhead', {})
        Runtime::Policy.new(
          redaction: redaction.fetch('mode', defaults[:redaction]),
          sampling_rate: sampling.fetch('rate', defaults[:sampling_rate]),
          max_events_per_second: overhead.fetch('max_events_per_second', defaults[:max_events_per_second]),
          max_events_per_session: overhead.fetch('max_events_per_session', defaults[:max_events_per_session]),
          max_record_bytes: overhead.fetch('max_record_bytes', defaults[:max_record_bytes]),
          max_session_bytes: overhead.fetch('max_session_bytes', defaults[:max_session_bytes]),
          fail_open: runtime.fetch('fail_open', defaults[:fail_open])
        )
      rescue RuntimeContractError => e
        field = e.message.split.first
        path = RUNTIME_POLICY_PATHS.fetch(field, 'runtime')
        raise ConfigurationError, "#{path} is invalid: #{e.message}"
      end

      def runtime_watchdog_policy_from(runtime)
        values = runtime.fetch('watchdog', {})
        defaults = Runtime::WatchdogPolicy::DEFAULTS
        Runtime::WatchdogPolicy.new(
          enabled: values.fetch('enabled', defaults[:enabled]),
          heartbeat_interval_ms: values.fetch('heartbeat_interval_ms', defaults[:heartbeat_interval_ms]),
          stall_threshold_ms: values.fetch('stall_threshold_ms', defaults[:stall_threshold_ms]),
          max_frames: values.fetch('max_frames', defaults[:max_frames])
        )
      rescue RuntimeContractError => e
        field = e.message.split.first
        path = field == 'enabled' ? 'runtime.watchdog.enabled' : "runtime.watchdog.#{field}"
        raise ConfigurationError, "#{path} is invalid: #{e.message}"
      end

      def runtime_operation_liveness_policy_from(runtime)
        values = runtime.fetch('operation_liveness', {})
        defaults = Runtime::OperationLivenessPolicy::DEFAULTS
        Runtime::OperationLivenessPolicy.new(
          enabled: values.fetch('enabled', defaults[:enabled]),
          poll_interval_ms: values.fetch('poll_interval_ms', defaults[:poll_interval_ms]),
          long_active_threshold_ms: values.fetch('long_active_threshold_ms', defaults[:long_active_threshold_ms])
        )
      rescue RuntimeContractError => e
        field = e.message.split.first
        raise ConfigurationError, "runtime.operation_liveness.#{field} is invalid: #{e.message}"
      end

      def check_unknown_keys(hash, allowed, path)
        unknown = hash.keys - allowed
        return if unknown.empty?

        sorted_allowed = allowed.sort.join(', ')
        raise ConfigurationError,
              "unknown configuration key '#{unknown.first}' at #{path} " \
              "(valid keys: #{sorted_allowed})"
      end
    end

    private

    def validate_types!(
      include_patterns, exclude_patterns, rules,
      formats, _severity, suppressions, runtime_policy, watchdog_policy,
      operation_liveness_policy
    )
      unless include_patterns.is_a?(Array) &&
             include_patterns.all?(String)
        raise ConfigurationError,
              'static.include must be an Array of Strings'
      end

      unless exclude_patterns.is_a?(Array) &&
             exclude_patterns.all?(String)
        raise ConfigurationError,
              'static.exclude must be an Array of Strings'
      end

      raise ConfigurationError, 'rules must be a Hash' unless rules.is_a?(Hash)

      validate_rules!(rules)
      validate_report_formats!(formats)

      unless runtime_policy.is_a?(Runtime::Policy)
        raise ConfigurationError,
              'runtime_policy must be a FiberAudit::Runtime::Policy'
      end
      unless watchdog_policy.is_a?(Runtime::WatchdogPolicy)
        raise ConfigurationError,
              'runtime_watchdog_policy must be a FiberAudit::Runtime::WatchdogPolicy'
      end
      unless operation_liveness_policy.is_a?(Runtime::OperationLivenessPolicy)
        raise ConfigurationError,
              'runtime_operation_liveness_policy must be a FiberAudit::Runtime::OperationLivenessPolicy'
      end

      return if suppressions.nil? || suppressions.is_a?(String)

      raise ConfigurationError,
            'static.suppressions_path must be nil or a String'
    end

    def validate_report_formats!(formats)
      unless formats.is_a?(Array)
        raise ConfigurationError,
              'report.formats must be an Array'
      end

      if formats.empty?
        raise ConfigurationError,
              'report.formats must not be empty'
      end

      invalid = formats.reject { |f| VALID_FORMATS.include?(f) }
      return if invalid.empty?

      raise ConfigurationError,
            "report.formats contains invalid: #{invalid.inspect} " \
            '(valid formats: text, json)'
    end

    def validate_rules!(rules)
      rules.each do |rule_id, entry|
        unless entry.is_a?(Hash)
          raise ConfigurationError,
                "rules.#{rule_id} must be a Hash, got #{entry.class}"
        end

        unknown = entry.keys - KNOWN_RULE_KEYS
        unless unknown.empty?
          sorted_allowed = KNOWN_RULE_KEYS.sort.join(', ')
          raise ConfigurationError,
                "unknown configuration key '#{unknown.first}' " \
                "in rules.#{rule_id} " \
                "(valid keys: #{sorted_allowed})"
        end

        if entry.key?('enabled') &&
           ![true, false].include?(entry['enabled'])
          raise ConfigurationError,
                "rules.#{rule_id}.enabled must be a Boolean"
        end

        next unless entry.key?('severity')

        coerce_severity(
          entry['severity'], "rules.#{rule_id}.severity"
        )
      end
    end

    # Centralized severity coercion.
    # Normalizes String to Symbol before delegating to Severity.coerce.
    # Raises path-anchored ConfigurationError for invalid types or values.
    def coerce_severity(value, path)
      normalized = case value
                   when Symbol
                     value
                   when String
                     value.to_sym
                   else
                     raise ConfigurationError,
                           "#{path} must be a String or Symbol, " \
                           "got #{value.class}"
                   end
      Severity.coerce(normalized)
    rescue ArgumentError
      raise ConfigurationError,
            "#{path} is not a valid severity: #{value.inspect}"
    end
  end
  # rubocop:enable Metrics/ClassLength
end
