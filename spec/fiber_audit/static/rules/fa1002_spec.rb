# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/rules/thread_join'
require 'fiber_audit/static/call_site'
require 'fiber_audit/configuration'

RSpec.describe FiberAudit::Static::Rules::ThreadJoin do
  let(:workspace) { nil }
  let(:context_resolver) { nil }
  let(:configuration) { FiberAudit::Configuration.new }
  let(:rule) { described_class.new(workspace: workspace, context_resolver: context_resolver, configuration: configuration) }

  def build_call_site(overrides = {})
    FiberAudit::Static::CallSite.new(
      path: 'test.rb',
      line: 1,
      column: 0,
      receiver_source: overrides[:receiver_source],
      receiver_constant: overrides[:receiver_constant],
      method_name: overrides[:method_name] || :join,
      arguments: [],
      enclosing_symbol: 'TestClass#test_method',
      nesting: ['TestClass'],
      execution_context: overrides[:execution_context] || :request,
      resolution: overrides[:resolution],
      confidence: overrides[:confidence] || :high
    )
  end

  describe '#analyze' do
    context 'positive cases' do
      it 'detects Thread.new.join (chained constructor)' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.rule_id).to eq('FA1002')
        expect(findings.first.operation).to eq('Thread.join')
        expect(findings.first.category).to eq(:synchronization)
      end

      it 'detects Thread.new.value (chained constructor)' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :value
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Thread.value')
      end

      it 'detects assigned receiver (t = Thread.new; t.join)' do
        cs = build_call_site(
          receiver_source: 't',
          receiver_constant: 'Thread',
          method_name: :join
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Thread.join')
      end

      it 'detects Thread.current with forced high confidence' do
        cs = build_call_site(
          receiver_source: 'Thread.current',
          receiver_constant: 'Thread',
          method_name: :join,
          confidence: :medium
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.confidence).to eq(:high)
      end

      it 'detects Thread.current.value' do
        cs = build_call_site(
          receiver_source: 'Thread.current',
          receiver_constant: 'Thread',
          method_name: :value
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.confidence).to eq(:high)
      end
    end

    context 'negative cases' do
      it 'skips direct Thread.join (receiver_source is bare Thread)' do
        cs = build_call_site(
          receiver_source: 'Thread',
          receiver_constant: 'Thread',
          method_name: :join
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'skips direct Thread.value (receiver_source is bare Thread)' do
        cs = build_call_site(
          receiver_source: 'Thread',
          receiver_constant: 'Thread',
          method_name: :value
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'skips arbitrary worker.join (receiver_constant is not Thread)' do
        cs = build_call_site(
          receiver_source: 'worker',
          receiver_constant: 'Worker',
          method_name: :join
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'skips wrong methods (not :join or :value)' do
        cs = build_call_site(
          receiver_source: 'thread',
          receiver_constant: 'Thread',
          method_name: :kill
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'skips when receiver_constant is nil' do
        cs = build_call_site(
          receiver_source: 'thread',
          receiver_constant: nil,
          method_name: :join
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'workspace shadowing' do
      let(:shadowed_workspace) do
        double('workspace', resolve_constant: 'CustomThread', semantic_index: nil)
      end
      let(:rule_with_shadow) do
        described_class.new(
          workspace: shadowed_workspace,
          context_resolver: context_resolver,
          configuration: configuration
        )
      end

      it 'skips when workspace.resolve_constant returns non-Thread' do
        cs = build_call_site(
          receiver_source: 't',
          receiver_constant: 'Thread',
          method_name: :join
        )
        findings = rule_with_shadow.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'detects when workspace has no Thread declaration' do
        normal_workspace = double('workspace', resolve_constant: nil, semantic_index: nil)
        rule_normal = described_class.new(
          workspace: normal_workspace,
          context_resolver: context_resolver,
          configuration: configuration
        )
        cs = build_call_site(
          receiver_source: 't',
          receiver_constant: 'Thread',
          method_name: :join
        )
        findings = rule_normal.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end

      context 'with semantic_index seam' do
        let(:shadowed_semantic_index) do
          double('semantic_index', resolve_constant: 'CustomThread')
        end
        let(:workspace_with_semantic) do
          double('workspace', semantic_index: shadowed_semantic_index)
        end
        let(:rule_with_semantic_shadow) do
          described_class.new(
            workspace: workspace_with_semantic,
            context_resolver: context_resolver,
            configuration: configuration
          )
        end

        it 'skips when semantic_index.resolve_constant returns non-Thread' do
          cs = build_call_site(
            receiver_source: 't',
            receiver_constant: 'Thread',
            method_name: :join
          )
          findings = rule_with_semantic_shadow.analyze(call_sites: [cs])
          expect(findings).to be_empty
        end
      end
    end

    context 'advisory severity (no context ceiling)' do
      it 'stays :low in request context (no escalation)' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join,
          execution_context: :request
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end

      it 'stays :low in middleware context (no escalation)' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join,
          execution_context: :middleware
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end

      it 'stays :low in callback context' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join,
          execution_context: :callback
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end

      it 'stays :low in unknown context' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join,
          execution_context: :unknown
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end
    end

    context 'with configuration override' do
      let(:override_config) do
        instance_double(FiberAudit::Configuration, severity_override: :medium)
      end
      let(:rule_with_override) do
        described_class.new(
          workspace: workspace,
          context_resolver: context_resolver,
          configuration: override_config
        )
      end

      it 'applies configuration override without context ceiling' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join,
          execution_context: :request
        )
        findings = rule_with_override.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'confidence' do
      it 'preserves call-site confidence for Thread.new.join' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join,
          confidence: :medium
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:medium)
      end

      it 'preserves call-site confidence for an assigned receiver' do
        cs = build_call_site(
          receiver_source: 't',
          receiver_constant: 'Thread',
          method_name: :join,
          confidence: :low
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:low)
      end

      it 'forces :high confidence for Thread.current' do
        cs = build_call_site(
          receiver_source: 'Thread.current',
          receiver_constant: 'Thread',
          method_name: :join,
          confidence: :low
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:high)
      end
    end

    context 'output fields' do
      it 'includes all required fields in finding' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join
        )
        finding = rule.analyze(call_sites: [cs]).first

        expect(finding.rule_id).to eq('FA1002')
        expect(finding.title).to eq('Thread wait')
        expect(finding.category).to eq(:synchronization)
        expect(finding.severity).to be_a(Symbol)
        expect(finding.confidence).to be_a(Symbol)
        expect(finding.location).to be_a(FiberAudit::Location)
        expect(finding.symbol).to eq('TestClass#test_method')
        expect(finding.operation).to eq('Thread.join')
        expect(finding.execution_context).to eq(:request)
        expect(finding.message).to eq(
          'Thread#join/value requires scheduler block/unblock cooperation in a non-blocking Fiber.'
        )
        expect(finding.evidence).to be_an(Array)
        expect(finding.evidence).not_to be_empty
        expect(finding.remediation).to eq(
          'Verify scheduler coordination and runtime progress, or move the wait outside the fiber-scheduled path.'
        )
      end

      it 'provides nonempty static evidence' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join
        )
        finding = rule.analyze(call_sites: [cs]).first
        evidence = finding.evidence.first

        expect(evidence).to be_a(FiberAudit::Evidence)
        expect(evidence.source).to eq('static_analysis')
        expect(evidence.message).to include('Thread.join')
        expect(evidence.details).to be_a(Hash)
        expect(evidence.details[:operation]).to eq('Thread.join')
        expect(evidence.details[:receiver]).to eq('Thread.new')
        expect(evidence.details[:canonical_operations]).to eq(%w[Thread.join Thread.value])
      end

      it 'generates stable fingerprint' do
        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join
        )
        finding1 = rule.analyze(call_sites: [cs]).first
        finding2 = rule.analyze(call_sites: [cs]).first

        expect(finding1.fingerprint).to eq(finding2.fingerprint)
        expect(finding1.fingerprint).to be_a(String)
        expect(finding1.fingerprint.length).to eq(64) # SHA256 hex digest
      end

      it 'keeps fingerprints stable when only the line changes' do
        cs1 = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join,
          line: 1
        )
        cs2 = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join,
          line: 2
        )
        finding1 = rule.analyze(call_sites: [cs1]).first
        finding2 = rule.analyze(call_sites: [cs2]).first

        expect(finding1.fingerprint).to eq(finding2.fingerprint)
      end
    end

    context 'adapter errors' do
      it 'does not raise when workspace.resolve_constant raises' do
        error_workspace = double('workspace')
        allow(error_workspace).to receive(:resolve_constant).and_raise(StandardError, 'adapter error')
        rule_with_error = described_class.new(
          workspace: error_workspace,
          context_resolver: context_resolver,
          configuration: configuration
        )

        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join
        )
        findings = rule_with_error.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end

      it 'does not raise when semantic_index.resolve_constant raises' do
        error_semantic = double('semantic_index')
        allow(error_semantic).to receive(:resolve_constant).and_raise(StandardError, 'semantic error')
        error_workspace = double('workspace', semantic_index: error_semantic)
        rule_with_error = described_class.new(
          workspace: error_workspace,
          context_resolver: context_resolver,
          configuration: configuration
        )

        cs = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join
        )
        findings = rule_with_error.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end
    end

    context 'multiple call sites' do
      it 'processes all matching call sites' do
        cs1 = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join
        )
        cs2 = build_call_site(
          receiver_source: 't',
          receiver_constant: 'Thread',
          method_name: :value
        )
        cs3 = build_call_site(
          receiver_source: 'Thread.current',
          receiver_constant: 'Thread',
          method_name: :join
        )
        findings = rule.analyze(call_sites: [cs1, cs2, cs3])
        expect(findings.size).to eq(3)
        expect(findings.map(&:operation)).to contain_exactly('Thread.join', 'Thread.value', 'Thread.join')
      end

      it 'filters out non-matching call sites' do
        cs1 = build_call_site(
          receiver_source: 'Thread.new',
          receiver_constant: 'Thread',
          method_name: :join
        )
        cs2 = build_call_site(
          receiver_source: 'Thread',
          receiver_constant: 'Thread',
          method_name: :join
        )
        cs3 = build_call_site(
          receiver_source: 'worker',
          receiver_constant: 'Worker',
          method_name: :join
        )
        findings = rule.analyze(call_sites: [cs1, cs2, cs3])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Thread.join')
        expect(findings.first.evidence.first.details[:receiver]).to eq('Thread.new')
      end
    end
  end

  describe 'class metadata' do
    it 'has correct id' do
      expect(described_class.id).to eq('FA1002')
    end

    it 'has correct default severity' do
      expect(described_class.severity).to eq(:low)
    end

    it 'has correct default confidence' do
      expect(described_class.confidence).to eq(:high)
    end

    it 'has correct description' do
      expect(described_class.description).to eq('Thread waits require scheduler block/unblock cooperation')
    end

    it 'has correct title constant' do
      expect(described_class::TITLE).to eq('Thread wait')
    end

    it 'has correct category constant' do
      expect(described_class::CATEGORY).to eq(:synchronization)
    end

    it 'has correct canonical operations' do
      expect(described_class::CANONICAL_OPS).to eq(%w[Thread.join Thread.value])
    end
  end
end
