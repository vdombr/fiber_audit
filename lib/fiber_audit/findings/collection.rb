# frozen_string_literal: true

module FiberAudit
  class EmptyEvidenceError < StandardError; end

  class Collection
    include Enumerable

    def initialize(findings = [])
      @findings = Array(findings)
    end

    def each(&)
      @findings.each(&)
    end

    def add(finding)
      if finding.evidence.nil? || finding.evidence.empty?
        raise EmptyEvidenceError,
              "Finding #{finding.rule_id} (#{finding.fingerprint[0, 8]}) cannot be published without evidence"
      end
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
  end
end
