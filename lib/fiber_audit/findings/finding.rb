# frozen_string_literal: true

module FiberAudit
  Finding = Data.define(
    :rule_id,
    :title,
    :category,
    :severity,
    :confidence,
    :location,
    :symbol,
    :operation,
    :execution_context,
    :message,
    :evidence,
    :remediation,
    :fingerprint
  ) do
    def initialize(
      rule_id:,
      category:, severity:, confidence:, message:, title: nil,
      location: nil,
      symbol: nil,
      operation: nil,
      execution_context: nil,
      evidence: [],
      remediation: nil,
      fingerprint: nil
    )
      severity = Severity.coerce(severity)
      confidence = Confidence.coerce(confidence)
      evidence = Array(evidence).freeze

      fingerprint ||= Correlation::Fingerprint.call(
        rule_id: rule_id,
        path: location&.path,
        enclosing_symbol: symbol,
        operation: operation
      )

      super(
        rule_id: rule_id,
        title: title,
        category: category,
        severity: severity,
        confidence: confidence,
        location: location,
        symbol: symbol,
        operation: operation,
        execution_context: execution_context,
        message: message,
        evidence: evidence,
        remediation: remediation,
        fingerprint: fingerprint
      )
    end

    def to_h_for_json
      {
        rule_id: rule_id,
        title: title,
        category: category,
        severity: severity,
        confidence: confidence,
        location: location&.to_h_for_json,
        symbol: symbol,
        operation: operation,
        execution_context: execution_context,
        message: message,
        evidence: evidence.map(&:to_h_for_json),
        remediation: remediation,
        fingerprint: fingerprint
      }
    end
  end
end
