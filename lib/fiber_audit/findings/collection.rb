# frozen_string_literal: true

require_relative '../errors'

module FiberAudit
  class Collection
    include Enumerable

    def initialize(findings = [])
      @findings = Array(findings).dup
      @findings.each { |f| validate_evidence!(f) }
    end

    def each(&)
      @findings.each(&)
    end

    def add(finding)
      validate_evidence!(finding)
      @findings << finding
      self
    end

    def by_rule(rule_id)
      @findings.select { _1.rule_id == rule_id }
    end

    def by_severity_min(min_severity)
      min_index = Severity.index(min_severity)
      @findings.select { Severity.index(_1.severity) <= min_index }
    end

    def size
      @findings.size
    end

    def empty?
      @findings.empty?
    end

    def to_a
      @findings.dup
    end

    def to_h_for_json
      @findings.map(&:to_h_for_json)
    end

    private

    def validate_evidence!(finding)
      return if finding.evidence&.any?

      raise EmptyEvidenceError,
            "Finding #{finding.rule_id} (#{finding.fingerprint[0, 8]}) cannot be published without evidence"
    end
  end
end
