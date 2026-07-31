# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FiberAudit::Finding do
  let(:location) { FiberAudit::Location.new(path: 'app/models/user.rb', line: 10, column: 5) }

  let(:evidence_items) do
    [
      FiberAudit::Evidence.new(source: :parser, message: 'blocking IO', details: { method: 'File.read' })
    ]
  end

  def build_finding(**overrides)
    defaults = {
      rule_id: 'FIB001',
      category: :blocking_io,
      severity: :high,
      confidence: :confirmed,
      location: location,
      symbol: 'User#import',
      operation: :blocking_read,
      message: 'Blocking file read in scheduler-aware context'
    }
    described_class.new(**defaults, **overrides)
  end

  describe 'auto-fingerprint' do
    it 'computes a fingerprint when none is supplied' do
      finding = build_finding
      expect(finding.fingerprint).not_to be_nil
      expect(finding.fingerprint).to match(/\A[0-9a-f]{64}\z/)
    end

    it 'produces the same fingerprint for identical inputs' do
      f1 = build_finding
      f2 = build_finding
      expect(f1.fingerprint).to eq(f2.fingerprint)
    end
  end

  describe 'explicit fingerprint' do
    it 'preserves an explicitly provided fingerprint' do
      explicit = 'a' * 64
      finding = build_finding(fingerprint: explicit)
      expect(finding.fingerprint).to eq(explicit)
    end
  end

  describe 'severity coercion' do
    it 'coerces a valid severity' do
      finding = build_finding(severity: :critical)
      expect(finding.severity).to eq(:critical)
    end

    it 'raises ArgumentError for an invalid severity' do
      expect { build_finding(severity: :nuclear) }.to raise_error(ArgumentError, /unknown severity/)
    end
  end

  describe 'confidence coercion' do
    it 'coerces a valid confidence' do
      finding = build_finding(confidence: :medium)
      expect(finding.confidence).to eq(:medium)
    end

    it 'raises ArgumentError for an invalid confidence' do
      expect { build_finding(confidence: :guess) }.to raise_error(ArgumentError, /unknown confidence/)
    end
  end

  describe '#to_h_for_json' do
    it 'returns a complete hash representation' do
      finding = build_finding(evidence: evidence_items)
      h = finding.to_h_for_json

      expect(h[:rule_id]).to eq('FIB001')
      expect(h[:category]).to eq(:blocking_io)
      expect(h[:severity]).to eq(:high)
      expect(h[:confidence]).to eq(:confirmed)
      expect(h[:location]).to eq(location.to_h_for_json)
      expect(h[:symbol]).to eq('User#import')
      expect(h[:operation]).to eq(:blocking_read)
      expect(h[:message]).to eq('Blocking file read in scheduler-aware context')
      expect(h[:evidence].size).to eq(1)
      expect(h[:evidence].first).to eq(evidence_items.first.to_h_for_json)
      expect(h[:fingerprint]).to eq(finding.fingerprint)
    end

    it 'handles nil location gracefully' do
      finding = build_finding(location: nil)
      h = finding.to_h_for_json
      expect(h[:location]).to be_nil
    end
  end

  describe 'to_h_for_json round-trip preserves fingerprint' do
    it 'produces an identical fingerprint after serialization and re-construction' do
      original = build_finding(evidence: evidence_items)
      h = original.to_h_for_json

      rebuilt = described_class.new(
        rule_id: h[:rule_id],
        category: h[:category],
        severity: h[:severity],
        confidence: h[:confidence],
        location: h[:location] ? FiberAudit::Location.new(**h[:location]) : nil,
        symbol: h[:symbol],
        operation: h[:operation],
        execution_context: h[:execution_context],
        message: h[:message],
        evidence: h[:evidence].map { |e| FiberAudit::Evidence.new(**e) },
        remediation: h[:remediation]
      )

      expect(rebuilt.fingerprint).to eq(original.fingerprint)
    end
  end

  describe 'evidence' do
    it 'is frozen' do
      finding = build_finding(evidence: evidence_items)
      expect(finding.evidence).to be_frozen
    end

    it 'defaults to an empty array' do
      finding = build_finding
      expect(finding.evidence).to eq([])
      expect(finding.evidence).to be_frozen
    end
  end
end
