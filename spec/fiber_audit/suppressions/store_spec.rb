# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/suppressions/store'
require 'fiber_audit/findings/severity'
require 'fiber_audit/findings/confidence'
require 'fiber_audit/findings/location'
require 'fiber_audit/findings/evidence'
require 'fiber_audit/findings/finding'
require 'fiber_audit/correlation/fingerprint'

RSpec.describe FiberAudit::Suppressions::Store do
  # Helper to build a minimal Finding for testing
  def build_finding(rule_id:, path: nil, line: nil, symbol: nil, operation: nil)
    location = (FiberAudit::Location.new(path: path, line: line, column: 0) if path && line)

    FiberAudit::Finding.new(
      rule_id: rule_id,
      category: :subprocess,
      severity: :high,
      confidence: :confirmed,
      location: location,
      symbol: symbol,
      operation: operation,
      message: 'test finding'
    )
  end

  describe '#apply' do
    context 'with inline suppressions' do
      it 'suppresses a finding matching path, line range, and rule_id' do
        inline = [
          FiberAudit::Suppressions::InlineSuppression.new(
            rule_id: 'FA1001',
            reason: 'safe subprocess',
            path: 'app/services/worker.rb',
            start_line: 5,
            end_line: 10
          )
        ]
        store = described_class.new(inline_suppressions: inline)

        finding_in_range = build_finding(rule_id: 'FA1001', path: 'app/services/worker.rb', line: 7)
        finding_outside = build_finding(rule_id: 'FA1001', path: 'app/services/worker.rb', line: 15)

        active, suppressed = store.apply([finding_in_range, finding_outside])

        expect(suppressed).to eq([finding_in_range])
        expect(active).to eq([finding_outside])
      end

      it 'does not suppress a finding with different rule_id' do
        inline = [
          FiberAudit::Suppressions::InlineSuppression.new(
            rule_id: 'FA1001',
            reason: 'safe',
            path: 'app/services/worker.rb',
            start_line: 1,
            end_line: 10
          )
        ]
        store = described_class.new(inline_suppressions: inline)

        finding = build_finding(rule_id: 'FA1002', path: 'app/services/worker.rb', line: 5)
        active, suppressed = store.apply([finding])

        expect(active).to eq([finding])
        expect(suppressed).to be_empty
      end

      it 'does not suppress a finding with different path' do
        inline = [
          FiberAudit::Suppressions::InlineSuppression.new(
            rule_id: 'FA1001',
            reason: 'safe',
            path: 'app/services/worker.rb',
            start_line: 1,
            end_line: 10
          )
        ]
        store = described_class.new(inline_suppressions: inline)

        finding = build_finding(rule_id: 'FA1001', path: 'app/services/other.rb', line: 5)
        active, suppressed = store.apply([finding])

        expect(active).to eq([finding])
        expect(suppressed).to be_empty
      end

      it 'does not suppress a finding without a location' do
        inline = [
          FiberAudit::Suppressions::InlineSuppression.new(
            rule_id: 'FA1001',
            reason: 'safe',
            path: 'app/services/worker.rb',
            start_line: 1,
            end_line: 10
          )
        ]
        store = described_class.new(inline_suppressions: inline)

        finding = build_finding(rule_id: 'FA1001') # no path/line
        active, suppressed = store.apply([finding])

        expect(active).to eq([finding])
        expect(suppressed).to be_empty
      end
    end

    context 'with YAML suppressions' do
      it 'suppresses a finding matching rule_id' do
        yaml_sups = [
          FiberAudit::Suppressions::YamlSuppression.new(
            rule: 'FA1001',
            symbol: nil,
            operation: nil,
            reason: 'Offline task'
          )
        ]
        store = described_class.new(yaml_suppressions: yaml_sups)

        finding = build_finding(rule_id: 'FA1001', path: 'any.rb', line: 1)
        active, suppressed = store.apply([finding])

        expect(suppressed).to eq([finding])
        expect(active).to be_empty
      end

      it 'suppresses a finding matching rule_id and symbol' do
        yaml_sups = [
          FiberAudit::Suppressions::YamlSuppression.new(
            rule: 'FA1001',
            symbol: 'DataMigration#run',
            operation: nil,
            reason: 'Offline task'
          )
        ]
        store = described_class.new(yaml_suppressions: yaml_sups)

        matching = build_finding(rule_id: 'FA1001', path: 'a.rb', line: 1, symbol: 'DataMigration#run')
        non_matching = build_finding(rule_id: 'FA1001', path: 'b.rb', line: 1, symbol: 'ApiController#index')

        active, suppressed = store.apply([matching, non_matching])

        expect(suppressed).to eq([matching])
        expect(active).to eq([non_matching])
      end

      it 'suppresses a finding matching rule_id and operation' do
        yaml_sups = [
          FiberAudit::Suppressions::YamlSuppression.new(
            rule: 'FA1001',
            symbol: nil,
            operation: 'Open3.capture3',
            reason: 'Wrapped safely'
          )
        ]
        store = described_class.new(yaml_suppressions: yaml_sups)

        matching = build_finding(rule_id: 'FA1001', path: 'a.rb', line: 1, operation: 'Open3.capture3')
        non_matching = build_finding(rule_id: 'FA1001', path: 'b.rb', line: 1, operation: 'system')

        active, suppressed = store.apply([matching, non_matching])

        expect(suppressed).to eq([matching])
        expect(active).to eq([non_matching])
      end

      it 'does not suppress a finding with different rule_id' do
        yaml_sups = [
          FiberAudit::Suppressions::YamlSuppression.new(
            rule: 'FA1001',
            symbol: nil,
            operation: nil,
            reason: 'Offline task'
          )
        ]
        store = described_class.new(yaml_suppressions: yaml_sups)

        finding = build_finding(rule_id: 'FA1002', path: 'a.rb', line: 1)
        active, suppressed = store.apply([finding])

        expect(active).to eq([finding])
        expect(suppressed).to be_empty
      end
    end

    context 'with both inline and YAML suppressions' do
      it 'suppresses findings matched by either mechanism' do
        inline = [
          FiberAudit::Suppressions::InlineSuppression.new(
            rule_id: 'FA1002',
            reason: 'test code',
            path: 'test.rb',
            start_line: 1,
            end_line: 10
          )
        ]
        yaml_sups = [
          FiberAudit::Suppressions::YamlSuppression.new(
            rule: 'FA1001',
            symbol: nil,
            operation: nil,
            reason: 'Offline task'
          )
        ]
        store = described_class.new(
          inline_suppressions: inline,
          yaml_suppressions: yaml_sups
        )

        f1 = build_finding(rule_id: 'FA1001', path: 'any.rb', line: 1)
        f2 = build_finding(rule_id: 'FA1002', path: 'test.rb', line: 5)
        f3 = build_finding(rule_id: 'FA1003', path: 'other.rb', line: 1)

        active, suppressed = store.apply([f1, f2, f3])

        expect(suppressed).to contain_exactly(f1, f2)
        expect(active).to eq([f3])
      end
    end

    context 'with no suppressions' do
      it 'returns all findings as active' do
        store = described_class.new

        f1 = build_finding(rule_id: 'FA1001', path: 'a.rb', line: 1)
        f2 = build_finding(rule_id: 'FA1002', path: 'b.rb', line: 2)

        active, suppressed = store.apply([f1, f2])

        expect(active).to eq([f1, f2])
        expect(suppressed).to be_empty
      end
    end
  end
end
