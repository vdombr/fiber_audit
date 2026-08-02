# frozen_string_literal: true

require_relative '../errors'
require_relative '../version'
require_relative '../findings/severity'
require_relative '../findings/confidence'

module FiberAudit
  module Reporters
    # Schema validates audit results and builds deterministic output hashes.
    # It enforces the publication invariant and structural constraints.
    #
    # Architecture:
    # - build(result): Converts result protocol to normalized primitive report Hash
    # - validate!(report_hash): Validates that Hash and returns it
    # - JSON/Text call build then validate
    # The complete external schema is centralized here so validation cannot
    # drift across reporters.
    # rubocop:disable Metrics/ModuleLength
    module Schema
      SCHEMA_VERSION = '1.0'
      DISCLAIMER = 'This is a static-only audit. PASS cannot be granted without runtime coverage.'
      ALLOWED_STATUSES = %w[FAIL REVIEW PASS_WITH_WARNINGS NO_FINDINGS].freeze
      ALLOWED_SEVERITIES = %w[critical high medium low info].freeze
      ALLOWED_CONFIDENCES = %w[confirmed high medium low unknown].freeze

      module_function

      # Builds a normalized primitive report hash from result protocol.
      # Normalizes Finding/Evidence/Location objects to JSON primitives.
      def build(result)
        validate_interface!(result)

        status = validate_status(result.status)
        findings = normalize_findings(result.findings)
        suppressed = normalize_findings(result.suppressed)
        parse_errors = normalize_parse_errors(result.parse_errors)
        coverage = normalize_coverage(result.coverage)

        summary = build_summary(findings, suppressed)

        {
          schema_version: SCHEMA_VERSION,
          tool_version: FiberAudit::VERSION,
          status: status,
          disclaimer: DISCLAIMER,
          summary: summary,
          coverage: coverage,
          findings: sort_findings(findings),
          suppressed: sort_findings(suppressed),
          parse_errors: parse_errors
        }
      end

      # Validates a report hash and returns it.
      # Raises ReporterError on any validation failure.
      def validate!(report_hash)
        validate_report_structure!(report_hash)
        validate_status_value!(report_hash[:status])
        validate_summary!(report_hash[:summary])
        validate_coverage!(report_hash[:coverage])
        validate_findings_array!(report_hash[:findings], 'findings')
        validate_findings_array!(report_hash[:suppressed], 'suppressed')
        validate_parse_errors!(report_hash[:parse_errors])
        verify_summary_consistency!(report_hash)

        report_hash.freeze
      end

      def validate_interface!(result)
        %i[findings suppressed parse_errors coverage status].each do |method|
          next if result.respond_to?(method)

          raise ReporterError, "result must respond to #{method}"
        end
      end

      def validate_status(status)
        status_str = status.to_s.upcase
        return status_str if ALLOWED_STATUSES.include?(status_str)

        raise ReporterError, "invalid status: #{status.inspect}, must be one of #{ALLOWED_STATUSES.join(', ')}"
      end

      def validate_report_structure!(report_hash)
        required_keys = %i[schema_version tool_version status disclaimer summary coverage findings suppressed parse_errors]
        actual_keys = report_hash.keys

        missing = required_keys - actual_keys
        raise ReporterError, "report missing required keys: #{missing.join(', ')}" unless missing.empty?

        unknown = actual_keys - required_keys
        return if unknown.empty?

        raise ReporterError, "report has unknown keys: #{unknown.join(', ')}"
      end

      def validate_status_value!(status)
        return if status.is_a?(String) && ALLOWED_STATUSES.include?(status)

        raise ReporterError, "invalid status: #{status.inspect}"
      end

      def validate_summary!(summary)
        required_keys = %i[critical high medium low info suppressed total]
        actual_keys = summary.keys

        missing = required_keys - actual_keys
        raise ReporterError, "summary missing required keys: #{missing.join(', ')}" unless missing.empty?

        unknown = actual_keys - required_keys
        raise ReporterError, "summary has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

        required_keys.each do |key|
          value = summary[key]
          raise ReporterError, "summary.#{key} must be a non-negative Integer" unless value.is_a?(Integer) && value >= 0
        end
      end

      def normalize_findings(findings_array)
        collection = findings_array.respond_to?(:to_a) ? findings_array.to_a : Array(findings_array)
        collection.map { |finding| normalize_finding(finding) }
      end

      def normalize_finding(finding)
        validate_finding_structure!(finding)

        rule_id = finding.rule_id.to_s
        message = finding.message.to_s
        fingerprint = finding.fingerprint.to_s
        severity = finding.severity.to_s
        confidence = finding.confidence.to_s

        validate_finding_strings!(rule_id, message, fingerprint, severity, confidence)

        location = normalize_location(finding.location)
        evidence = normalize_evidence(finding.evidence, rule_id)

        {
          rule_id: rule_id,
          title: normalize_optional_field(finding.title, 'title'),
          category: normalize_optional_field(finding.category, 'category'),
          severity: severity,
          confidence: confidence,
          location: location,
          symbol: normalize_optional_field(finding.symbol, 'symbol'),
          operation: normalize_optional_field(finding.operation, 'operation'),
          execution_context: normalize_optional_field(finding.execution_context, 'execution_context'),
          message: message,
          evidence: evidence,
          remediation: normalize_optional_field(finding.remediation, 'remediation'),
          fingerprint: fingerprint
        }
      end

      def validate_finding_structure!(finding)
        %i[rule_id severity confidence message evidence fingerprint].each do |method|
          next if finding.respond_to?(method)

          raise ReporterError, "finding must respond to #{method}"
        end
      end

      def validate_finding_strings!(rule_id, message, fingerprint, severity, confidence)
        raise ReporterError, 'finding rule_id must be non-empty' if rule_id.empty?

        raise ReporterError, 'finding message must be non-empty' if message.empty?

        raise ReporterError, 'finding fingerprint must be non-empty' if fingerprint.empty?

        raise ReporterError, "finding has invalid severity: #{severity.inspect}" unless ALLOWED_SEVERITIES.include?(severity)

        return if ALLOWED_CONFIDENCES.include?(confidence)

        raise ReporterError, "finding has invalid confidence: #{confidence.inspect}"
      end

      def normalize_optional_field(value, field)
        return nil if value.nil?
        return value.to_s if value.is_a?(Symbol)
        return value if json_safe?(value)

        raise ReporterError, "finding.#{field} is not JSON-safe: #{value.class}"
      end

      def normalize_location(location)
        return nil if location.nil?
        return nil unless location.respond_to?(:path)

        path = location.path.to_s
        line = location.respond_to?(:line) ? location.line : nil
        column = location.respond_to?(:column) ? location.column : nil

        validate_location!(path, line, column)

        { path: path, line: line, column: column }
      end

      def validate_location!(path, line, column)
        raise ReporterError, 'location path must be non-empty string' if path.empty?

        unless line.nil? || (line.is_a?(Integer) && line.positive?)
          raise ReporterError, "location line must be positive Integer or nil, got: #{line.inspect}"
        end

        return if column.nil? || (column.is_a?(Integer) && column >= 0)

        raise ReporterError, "location column must be non-negative Integer or nil, got: #{column.inspect}"
      end

      def normalize_evidence(evidence_array, rule_id)
        collection = evidence_array.respond_to?(:to_a) ? evidence_array.to_a : Array(evidence_array)

        raise ReporterError, "Finding (#{rule_id}) must have non-empty evidence (publication invariant)" if collection.empty?

        collection.map.with_index do |ev, idx|
          normalize_evidence_record(ev, rule_id, idx)
        end
      end

      def normalize_evidence_record(evidence, rule_id, idx)
        %i[source message].each do |method|
          next if evidence.respond_to?(method)

          raise ReporterError, "Finding (#{rule_id}) evidence[#{idx}] must respond to #{method}"
        end

        source = evidence.source.to_s
        message = evidence.message.to_s

        raise ReporterError, "Finding (#{rule_id}) evidence[#{idx}].source must be non-empty" if source.empty?

        raise ReporterError, "Finding (#{rule_id}) evidence[#{idx}].message must be non-empty" if message.empty?

        details = evidence.respond_to?(:details) ? evidence.details : {}
        normalized_details = normalize_json_value(details, rule_id, idx)

        { source: source, message: message, details: normalized_details }
      end

      def normalize_json_value(value, rule_id, evidence_index)
        case value
        when Symbol
          value.to_s
        when Hash
          value.each_with_object({}) do |(key, nested), normalized|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ReporterError, details_error(rule_id, evidence_index, key.class)
            end

            normalized[key.to_s] = normalize_json_value(nested, rule_id, evidence_index)
          end
        when Array
          value.map { |nested| normalize_json_value(nested, rule_id, evidence_index) }
        else
          return value if json_safe?(value)

          raise ReporterError, details_error(rule_id, evidence_index, value.class)
        end
      end

      def details_error(rule_id, evidence_index, value_class)
        "Finding (#{rule_id}) evidence[#{evidence_index}].details is not JSON-safe: #{value_class}"
      end

      def json_safe?(value)
        value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false || value.nil?
      end

      def json_safe_recursive?(value)
        case value
        when Hash
          value.all? { |k, v| json_safe?(k) && json_safe_recursive?(v) }
        when Array
          value.all? { |item| json_safe_recursive?(item) }
        else
          json_safe?(value)
        end
      end

      def normalize_parse_errors(parse_errors_array)
        collection = parse_errors_array.respond_to?(:to_a) ? parse_errors_array.to_a : Array(parse_errors_array)
        collection.map { |error| normalize_parse_error(error) }
      end

      def normalize_parse_error(error)
        unless error.respond_to?(:path) && error.respond_to?(:message)
          raise ReporterError, 'parse error must respond to :path and :message'
        end

        path = error.path.to_s
        message = error.message.to_s

        raise ReporterError, 'parse error path must be non-empty' if path.empty?

        raise ReporterError, 'parse error message must be non-empty' if message.empty?

        line = error.respond_to?(:line) ? error.line : nil

        unless line.nil? || (line.is_a?(Integer) && line.positive?)
          raise ReporterError, "parse error line must be positive Integer or nil, got: #{line.inspect}"
        end

        { path: path, message: message, line: line }
      end

      def normalize_coverage(coverage)
        unless coverage.respond_to?(:analysed_files) &&
               coverage.respond_to?(:total_call_sites) &&
               coverage.respond_to?(:rules_run)
          raise ReporterError, 'coverage must respond to :analysed_files, :total_call_sites, :rules_run'
        end

        analysed_files = coverage.analysed_files
        total_call_sites = coverage.total_call_sites
        rules_run = coverage.rules_run

        validate_non_negative_integer!(analysed_files, 'coverage.analysed_files')
        validate_non_negative_integer!(total_call_sites, 'coverage.total_call_sites')
        validate_non_negative_integer!(rules_run, 'coverage.rules_run')

        {
          analysed_files: analysed_files,
          total_call_sites: total_call_sites,
          rules_run: rules_run
        }
      end

      def validate_coverage!(coverage)
        required_keys = %i[analysed_files total_call_sites rules_run]
        actual_keys = coverage.keys

        missing = required_keys - actual_keys
        raise ReporterError, "coverage missing required keys: #{missing.join(', ')}" unless missing.empty?

        unknown = actual_keys - required_keys
        raise ReporterError, "coverage has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

        required_keys.each do |key|
          value = coverage[key]
          validate_non_negative_integer!(value, "coverage.#{key}")
        end
      end

      def verify_summary_consistency!(report_hash)
        summary = report_hash[:summary]
        findings = report_hash[:findings]
        suppressed = report_hash[:suppressed]

        counts = Hash.new(0)
        findings.each { |f| counts[f[:severity]] += 1 }

        %w[critical high medium low info].each do |sev|
          expected = counts[sev]
          actual = summary[sev.to_sym]
          unless actual == expected
            raise ReporterError, "summary.#{sev} count (#{actual}) does not match findings (#{expected})"
          end
        end

        unless summary[:suppressed] == suppressed.size
          raise ReporterError,
                "summary.suppressed (#{summary[:suppressed]}) does not match suppressed array size (#{suppressed.size})"
        end

        return if summary[:total] == findings.size

        raise ReporterError, "summary.total (#{summary[:total]}) does not match findings count (#{findings.size})"
      end

      def validate_non_negative_integer!(value, field_name)
        return if value.is_a?(Integer) && value >= 0

        raise ReporterError, "#{field_name} must be a non-negative Integer, got: #{value.inspect}"
      end

      def validate_findings_array!(findings_array, context)
        raise ReporterError, "#{context} must be an Array" unless findings_array.is_a?(Array)

        findings_array.each_with_index do |finding, idx|
          validate_finding_hash!(finding, context, idx)
        end
      end

      # The field-by-field checks intentionally mirror Finding's public shape.
      # rubocop:disable Metrics/AbcSize
      def validate_finding_hash!(finding, context, idx)
        raise ReporterError, "#{context}[#{idx}] must be a Hash" unless finding.is_a?(Hash)

        required_keys = %i[rule_id title category severity confidence location symbol operation execution_context message
                           evidence remediation fingerprint]
        actual_keys = finding.keys

        missing = required_keys - actual_keys
        raise ReporterError, "#{context}[#{idx}] missing required keys: #{missing.join(', ')}" unless missing.empty?

        unknown = actual_keys - required_keys
        raise ReporterError, "#{context}[#{idx}] has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

        %i[rule_id message fingerprint].each do |key|
          value = finding[key]
          unless value.is_a?(String) && !value.empty?
            raise ReporterError, "#{context}[#{idx}].#{key} must be non-empty string"
          end
        end

        unless finding[:severity].is_a?(String) && ALLOWED_SEVERITIES.include?(finding[:severity])
          raise ReporterError, "#{context}[#{idx}].severity must be known severity string"
        end

        unless finding[:confidence].is_a?(String) && ALLOWED_CONFIDENCES.include?(finding[:confidence])
          raise ReporterError, "#{context}[#{idx}].confidence must be known confidence string"
        end

        %i[title category symbol operation execution_context remediation].each do |key|
          value = finding[key]
          next if value.nil?
          next if json_safe?(value)

          raise ReporterError, "#{context}[#{idx}].#{key} is not JSON-safe"
        end

        validate_location_hash!(finding[:location], context, idx)
        validate_evidence_array!(finding[:evidence], context, idx)
      end
      # rubocop:enable Metrics/AbcSize

      def validate_location_hash!(location, context, idx)
        return if location.nil?

        raise ReporterError, "#{context}[#{idx}].location must be a Hash or nil" unless location.is_a?(Hash)

        required_keys = %i[path line column]
        actual_keys = location.keys

        missing = required_keys - actual_keys
        raise ReporterError, "#{context}[#{idx}].location missing required keys: #{missing.join(', ')}" unless missing.empty?

        unknown = actual_keys - required_keys
        raise ReporterError, "#{context}[#{idx}].location has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

        path = location[:path]
        line = location[:line]
        column = location[:column]

        unless path.is_a?(String) && !path.empty?
          raise ReporterError, "#{context}[#{idx}].location.path must be non-empty string"
        end

        unless line.nil? || (line.is_a?(Integer) && line.positive?)
          raise ReporterError, "#{context}[#{idx}].location.line must be positive Integer or nil"
        end

        return if column.nil? || (column.is_a?(Integer) && column >= 0)

        raise ReporterError, "#{context}[#{idx}].location.column must be non-negative Integer or nil"
      end

      def validate_evidence_array!(evidence_array, context, idx)
        unless evidence_array.is_a?(Array) && !evidence_array.empty?
          raise ReporterError, "#{context}[#{idx}].evidence must be non-empty Array"
        end

        evidence_array.each_with_index do |evidence, evidence_idx|
          validate_evidence_hash!(evidence, context, idx, evidence_idx)
        end
      end

      def validate_evidence_hash!(evidence, context, idx, evidence_idx)
        unless evidence.is_a?(Hash)
          message = "#{context}[#{idx}].evidence[#{evidence_idx}] must be a Hash"
          raise ReporterError, message
        end

        required_keys = %i[source message details]
        actual_keys = evidence.keys

        missing = required_keys - actual_keys
        unless missing.empty?
          raise ReporterError, "#{context}[#{idx}].evidence[#{evidence_idx}] missing required keys: #{missing.join(', ')}"
        end

        unknown = actual_keys - required_keys
        unless unknown.empty?
          raise ReporterError, "#{context}[#{idx}].evidence[#{evidence_idx}] has unknown keys: #{unknown.join(', ')}"
        end

        source = evidence[:source]
        message = evidence[:message]

        unless source.is_a?(String) && !source.empty?
          raise ReporterError, "#{context}[#{idx}].evidence[#{evidence_idx}].source must be non-empty string"
        end

        unless message.is_a?(String) && !message.empty?
          raise ReporterError, "#{context}[#{idx}].evidence[#{evidence_idx}].message must be non-empty string"
        end

        details = evidence[:details]
        return if details.nil? || json_safe_recursive?(details)

        raise ReporterError, "#{context}[#{idx}].evidence[#{evidence_idx}].details is not JSON-safe"
      end

      def validate_parse_errors!(parse_errors)
        raise ReporterError, 'parse_errors must be an Array' unless parse_errors.is_a?(Array)

        parse_errors.each_with_index do |error, idx|
          validate_parse_error_hash!(error, idx)
        end
      end

      def validate_parse_error_hash!(error, idx)
        raise ReporterError, "parse_errors[#{idx}] must be a Hash" unless error.is_a?(Hash)

        required_keys = %i[path message line]
        actual_keys = error.keys

        missing = required_keys - actual_keys
        raise ReporterError, "parse_errors[#{idx}] missing required keys: #{missing.join(', ')}" unless missing.empty?

        unknown = actual_keys - required_keys
        raise ReporterError, "parse_errors[#{idx}] has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

        path = error[:path]
        message = error[:message]
        line = error[:line]

        raise ReporterError, "parse_errors[#{idx}].path must be non-empty string" unless path.is_a?(String) && !path.empty?

        unless message.is_a?(String) && !message.empty?
          raise ReporterError, "parse_errors[#{idx}].message must be non-empty string"
        end

        return if line.nil? || (line.is_a?(Integer) && line.positive?)

        raise ReporterError, "parse_errors[#{idx}].line must be positive Integer or nil"
      end

      def build_summary(findings, suppressed)
        counts = {
          critical: 0,
          high: 0,
          medium: 0,
          low: 0,
          info: 0
        }

        findings.each do |finding|
          severity = finding[:severity].to_sym
          counts[severity] += 1 if counts.key?(severity)
        end

        counts[:suppressed] = suppressed.size
        counts[:total] = findings.size

        counts.freeze
      end

      def sort_findings(findings)
        findings.sort_by do |f|
          [
            Severity.index(f[:severity].to_sym),
            f[:rule_id].to_s,
            f[:location] ? f[:location][:path].to_s : '',
            f[:location] ? (f[:location][:line] || Float::INFINITY) : Float::INFINITY,
            f[:fingerprint].to_s
          ]
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
