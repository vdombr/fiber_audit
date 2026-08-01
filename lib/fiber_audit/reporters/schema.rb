# frozen_string_literal: true

require_relative '../errors'
require_relative '../version'
require_relative '../findings/severity'
require_relative '../findings/confidence'

module FiberAudit
  module Reporters
    # Schema validates audit results and builds deterministic output hashes.
    # It enforces the publication invariant and structural constraints.
    module Schema
      SCHEMA_VERSION = '1.0'
      DISCLAIMER = 'This is a static-only audit. PASS cannot be granted without runtime coverage.'
      ALLOWED_STATUSES = %w[FAIL REVIEW PASS_WITH_WARNINGS NO_FINDINGS].freeze

      module_function

      # Validates the result and returns a deterministic hash.
      # Raises ReporterError on any validation failure.
      def validate!(result)
        validate_interface!(result)

        status = validate_status(result.status)
        findings = validate_findings(result.findings)
        suppressed = validate_suppressed(result.suppressed)
        parse_errors = validate_parse_errors(result.parse_errors)
        coverage = validate_coverage(result.coverage)

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
        }.freeze
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

      def validate_findings(findings_array)
        collection = findings_array.respond_to?(:to_a) ? findings_array.to_a : Array(findings_array)
        collection.each_with_index do |finding, idx|
          validate_finding(finding, idx)
        end
        collection
      end

      def validate_finding(finding, idx)
        validate_evidence!(finding, idx)
        validate_severity!(finding, idx)
        validate_confidence!(finding, idx)
        validate_location!(finding, idx)
        validate_json_safe!(finding, idx)
      end

      def validate_evidence!(finding, idx)
        evidence = finding.evidence
        return if evidence.is_a?(Array) && !evidence.empty?

        raise ReporterError, "Finding at index #{idx} (#{finding.rule_id}) must have non-empty evidence (publication invariant)"
      end

      def validate_severity!(finding, idx)
        severity = finding.severity
        return if Severity::LEVELS.include?(severity.to_sym)

        raise ReporterError, "Finding at index #{idx} (#{finding.rule_id}) has invalid severity: #{severity.inspect}"
      end

      def validate_confidence!(finding, idx)
        confidence = finding.confidence
        return if Confidence::LEVELS.include?(confidence.to_sym)

        raise ReporterError, "Finding at index #{idx} (#{finding.rule_id}) has invalid confidence: #{confidence.inspect}"
      end

      def validate_location!(finding, idx)
        location = finding.location
        return if location.nil?
        return if location.respond_to?(:path) && location.path.is_a?(String)

        raise ReporterError, "Finding at index #{idx} (#{finding.rule_id}) has invalid location"
      end

      def validate_json_safe!(finding, idx)
        # Ensure all fields can be serialized to JSON
        %i[rule_id title category message].each do |field|
          value = finding.respond_to?(field) ? finding.send(field) : nil
          next if value.nil?
          next if value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

          raise ReporterError, "Finding at index #{idx} (#{finding.rule_id}) field #{field} is not JSON-safe: #{value.class}"
        end

        validate_evidence_json_safe!(finding, idx)
      end

      def validate_evidence_json_safe!(finding, idx)
        finding.evidence.each_with_index do |ev, ev_idx|
          %i[source message].each do |field|
            value = ev.respond_to?(field) ? ev.send(field) : nil
            next if value.nil?
            next if value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

            raise ReporterError, "Finding at index #{idx} (#{finding.rule_id}) evidence[#{ev_idx}].#{field} is not JSON-safe: #{value.class}"
          end

          details = ev.respond_to?(:details) ? ev.details : nil
          next if details.nil? || details.empty?

          validate_details_json_safe!(details, idx, finding.rule_id, ev_idx)
        end
      end

      def validate_details_json_safe!(details, idx, rule_id, ev_idx)
        return if details.is_a?(Hash) || details.is_a?(Array)
        return if details.is_a?(String) || details.is_a?(Numeric) || details == true || details == false || details.nil?

        raise ReporterError, "Finding at index #{idx} (#{rule_id}) evidence[#{ev_idx}].details is not JSON-safe: #{details.class}"
      end

      def validate_suppressed(suppressed_array)
        collection = suppressed_array.respond_to?(:to_a) ? suppressed_array.to_a : Array(suppressed_array)
        collection.each_with_index do |finding, idx|
          validate_finding(finding, idx)
        end
        collection
      end

      def validate_parse_errors(parse_errors_array)
        collection = parse_errors_array.respond_to?(:to_a) ? parse_errors_array.to_a : Array(parse_errors_array)
        collection.map.with_index do |error, idx|
          validate_parse_error(error, idx)
        end
      end

      def validate_parse_error(error, idx)
        unless error.respond_to?(:path) && error.respond_to?(:message)
          raise ReporterError, "Parse error at index #{idx} must respond to :path and :message"
        end

        path = error.path
        message = error.message

        raise ReporterError, "Parse error at index #{idx} path must be a String" unless path.is_a?(String)
        raise ReporterError, "Parse error at index #{idx} message must be a String" unless message.is_a?(String)

        line = error.respond_to?(:line) ? error.line : nil
        unless line.nil? || line.is_a?(Integer)
          raise ReporterError, "Parse error at index #{idx} line must be Integer or nil"
        end

        { path: path, message: message, line: line }.freeze
      end

      def validate_coverage(coverage)
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
        }.freeze
      end

      def validate_non_negative_integer!(value, field_name)
        return if value.is_a?(Integer) && value >= 0

        raise ReporterError, "#{field_name} must be a non-negative Integer, got: #{value.inspect}"
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
          severity = finding.severity.to_sym
          counts[severity] += 1 if counts.key?(severity)
        end

        counts[:suppressed] = suppressed.size
        counts[:total_active] = findings.size

        counts.freeze
      end

      def sort_findings(findings)
        findings.sort_by do |f|
          [
            Severity.index(f.severity.to_sym),
            f.rule_id.to_s,
            f.location&.path.to_s,
            f.location&.line || Float::INFINITY,
            f.fingerprint.to_s
          ]
        end
      end
    end
  end
end
