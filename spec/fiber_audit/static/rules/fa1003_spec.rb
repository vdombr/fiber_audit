# frozen_string_literal: true

require 'fiber_audit/static/rules/synchronization'
require 'fiber_audit/static/call_site'
require 'fiber_audit/configuration'

RSpec.describe FiberAudit::Static::Rules::Synchronization do
  # ── Test Doubles ──────────────────────────────────────────────────────
  # A plain-object workspace with selective seams (no respond_to? stubbing).
  let(:workspace) do
    Class.new do
      attr_accessor :ancestors_map, :shadowed_constants, :semantic_index

      def initialize
        @ancestors_map = {}
        @shadowed_constants = []
        @semantic_index = nil
      end

      def ancestors_of(name)
        @ancestors_map[name] || []
      end
    end.new
  end

  let(:semantic_index) do
    Class.new do
      attr_accessor :shadowed_constants

      def initialize
        @shadowed_constants = []
      end

      def resolve_constant(name, nesting: [])
        _ = nesting
        return nil unless @shadowed_constants.include?(name.to_s)

        # Non-nil signals workspace-local definition (shadow).
        :shadowed
      end

      def ancestors_of(_name)
        []
      end
    end.new
  end

  let(:context_resolver) { double('context_resolver') }
  let(:configuration) do
    instance_double(FiberAudit::Configuration, severity_override: nil, rule_enabled?: true)
  end

  subject(:rule) do
    described_class.new(
      workspace: workspace,
      context_resolver: context_resolver,
      configuration: configuration
    )
  end

  before do
    workspace.semantic_index = semantic_index
  end

  # Helper to build a CallSite with sensible defaults.
  def build_site(**overrides)
    defaults = {
      path: 'app/models/worker.rb',
      line: 10,
      column: 2,
      receiver_source: 'mutex',
      receiver_constant: 'Mutex',
      method_name: :lock,
      arguments: [],
      enclosing_symbol: 'Worker#perform',
      nesting: ['Worker'],
      execution_context: :unknown,
      resolution: 'Mutex#lock',
      confidence: :high
    }
    FiberAudit::Static::CallSite.new(**defaults, **overrides)
  end

  # ── Metadata ──────────────────────────────────────────────────────────
  describe 'metadata' do
    it 'has the FA1003 identifier' do
      expect(described_class.id).to eq('FA1003')
    end

    it 'has medium default severity' do
      expect(described_class.severity).to eq(:medium)
    end

    it 'has high default confidence' do
      expect(described_class.default_confidence).to eq(:high)
    end

    it 'has a non-empty description' do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end

    it 'exposes RULE_TITLE constant' do
      expect(described_class::RULE_TITLE).to eq('Thread synchronization')
    end

    it 'exposes RULE_CATEGORY as :synchronization' do
      expect(described_class::RULE_CATEGORY).to eq(:synchronization)
    end
  end

  # ── Explicit receiver targets ─────────────────────────────────────────
  describe 'explicit receiver targets' do
    it 'detects Mutex#lock' do
      site = build_site(receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock)
      findings = rule.analyze(call_sites: [site])

      expect(findings.size).to eq(1)
      expect(findings.first.operation).to eq('Mutex#lock')
      expect(findings.first.message).to include('block the thread')
    end

    it 'detects Mutex#synchronize' do
      site = build_site(receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :synchronize)
      findings = rule.analyze(call_sites: [site])

      expect(findings.size).to eq(1)
      expect(findings.first.operation).to eq('Mutex#synchronize')
    end

    it 'detects ConditionVariable#wait' do
      site = build_site(
        receiver_source: 'cv', receiver_constant: 'ConditionVariable', method_name: :wait
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.size).to eq(1)
      expect(findings.first.operation).to eq('ConditionVariable#wait')
    end

    it 'detects Monitor#synchronize' do
      site = build_site(
        receiver_source: 'monitor', receiver_constant: 'Monitor', method_name: :synchronize
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.size).to eq(1)
      expect(findings.first.operation).to eq('Monitor#synchronize')
    end

    it 'detects Mutex#try_lock with fixed :info severity' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :try_lock,
        execution_context: :request
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.size).to eq(1)
      expect(findings.first.severity).to eq(:info)
      expect(findings.first.confidence).to eq(:high)
      expect(findings.first.message).to include('non-blocking')
    end
  end

  # ── Implicit MonitorMixin synchronize ─────────────────────────────────
  describe 'implicit MonitorMixin synchronize' do
    it 'detects synchronize without receiver when class includes MonitorMixin' do
      workspace.ancestors_map['MyService'] = %w[MonitorMixin Object Kernel BasicObject]

      site = build_site(
        receiver_source: nil, receiver_constant: nil, method_name: :synchronize,
        enclosing_symbol: 'MyService#process'
      )

      findings = rule.analyze(call_sites: [site])
      expect(findings.size).to eq(1)
      expect(findings.first.operation).to eq('MonitorMixin#synchronize')
    end

    it 'detects via semantic_index.ancestors_of fallback' do
      allow(semantic_index).to receive(:ancestors_of).with('MyService').and_return(['MonitorMixin'])
      semantic_workspace = Struct.new(:semantic_index).new(semantic_index)
      semantic_rule = described_class.new(
        workspace: semantic_workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
      site = build_site(
        receiver_source: nil, receiver_constant: nil, method_name: :synchronize,
        enclosing_symbol: 'MyService#process'
      )

      findings = semantic_rule.analyze(call_sites: [site])
      expect(findings.size).to eq(1)
    end

    it 'does not detect synchronize without MonitorMixin ancestry' do
      workspace.ancestors_map['MyService'] = %w[Object Kernel BasicObject]

      site = build_site(
        receiver_source: nil, receiver_constant: nil, method_name: :synchronize,
        enclosing_symbol: 'MyService#process'
      )

      findings = rule.analyze(call_sites: [site])
      expect(findings).to be_empty
    end

    it 'does not detect implicit methods other than synchronize' do
      workspace.ancestors_map['MyService'] = ['MonitorMixin']

      site = build_site(
        receiver_source: nil, receiver_constant: nil, method_name: :lock,
        enclosing_symbol: 'MyService#process'
      )

      findings = rule.analyze(call_sites: [site])
      expect(findings).to be_empty
    end
  end

  # ── .new chain receivers ──────────────────────────────────────────────
  describe '.new chain receivers' do
    it 'detects Mutex.new.lock (constructor chain)' do
      site = build_site(
        receiver_source: 'Mutex.new', receiver_constant: 'Mutex', method_name: :lock
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.size).to eq(1)
      expect(findings.first.operation).to eq('Mutex#lock')
    end
  end

  # ── Negative cases ────────────────────────────────────────────────────
  describe 'negative cases' do
    it 'rejects direct literal constant receiver (Mutex.lock)' do
      site = build_site(
        receiver_source: 'Mutex', receiver_constant: 'Mutex', method_name: :lock
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings).to be_empty
    end

    it 'rejects direct literal constant receiver (Monitor.synchronize)' do
      site = build_site(
        receiver_source: 'Monitor', receiver_constant: 'Monitor', method_name: :synchronize
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings).to be_empty
    end

    it 'rejects workspace-shadowed Mutex' do
      semantic_index.shadowed_constants = ['Mutex']

      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock,
        nesting: ['MyModule']
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings).to be_empty
    end

    it 'ignores non-target constants' do
      site = build_site(
        receiver_source: 'thread', receiver_constant: 'Thread', method_name: :join
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings).to be_empty
    end

    it 'ignores non-target methods on target constants' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :new
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings).to be_empty
    end

    it 'ignores unrelated methods with matching name on non-target' do
      site = build_site(
        receiver_source: 'lock', receiver_constant: nil, method_name: :lock
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings).to be_empty
    end
  end

  # ── Severity and context escalation ───────────────────────────────────
  describe 'severity escalation' do
    it 'escalates to :critical in request context' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock,
        execution_context: :request
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.first.severity).to eq(:critical)
    end

    it 'escalates to :medium in rake_task context' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock,
        execution_context: :rake_task
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.first.severity).to eq(:medium)
    end

    it 'keeps :medium in unknown context' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock,
        execution_context: :unknown
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.first.severity).to eq(:medium)
    end

    it 'Mutex#try_lock stays :info even in request context (bypass)' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :try_lock,
        execution_context: :request
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.first.severity).to eq(:info)
      expect(findings.first.confidence).to eq(:high)
    end

    it 'Mutex#try_lock stays :info in rake_task context (bypass)' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :try_lock,
        execution_context: :rake_task
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.first.severity).to eq(:info)
    end
  end

  # ── Configuration override ────────────────────────────────────────────
  describe 'configuration override' do
    let(:configuration) do
      instance_double(FiberAudit::Configuration, severity_override: :low, rule_enabled?: true)
    end

    it 'applies configuration override for normal operations' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock,
        execution_context: :unknown
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.first.severity).to eq(:low)
    end

    it 'Mutex#try_lock bypasses configuration override' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :try_lock,
        execution_context: :unknown
      )
      findings = rule.analyze(call_sites: [site])

      expect(findings.first.severity).to eq(:info)
    end
  end

  # ── Finding structure ─────────────────────────────────────────────────
  describe 'finding structure' do
    it 'populates all required fields' do
      site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock,
        enclosing_symbol: 'Worker#perform', execution_context: :request
      )
      finding = rule.analyze(call_sites: [site]).first

      expect(finding.rule_id).to eq('FA1003')
      expect(finding.title).to eq('Thread synchronization')
      expect(finding.category).to eq(:synchronization)
      expect(finding.severity).to eq(:critical)
      expect(finding.confidence).to eq(:high)
      expect(finding.location).to eq(site.location)
      expect(finding.symbol).to eq('Worker#perform')
      expect(finding.operation).to eq('Mutex#lock')
      expect(finding.execution_context).to eq(:request)
      expect(finding.message).to include('block the thread')
      expect(finding.evidence).to be_an(Array)
      expect(finding.evidence.size).to eq(1)
      expect(finding.remediation).to include('scheduler-aware')
      expect(finding.fingerprint).to be_a(String)
      expect(finding.fingerprint).not_to be_empty
    end

    it 'generates canonical operation format (Constant#method)' do
      site = build_site(receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock)
      finding = rule.analyze(call_sites: [site]).first

      expect(finding.operation).to match(/\A[A-Z][A-Za-z:]+#\w+\z/)
    end

    it 'generates distinct fingerprints for distinct operations' do
      lock_site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock
      )
      sync_site = build_site(
        receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :synchronize
      )

      findings = rule.analyze(call_sites: [lock_site, sync_site])

      expect(findings.size).to eq(2)
      expect(findings[0].fingerprint).not_to eq(findings[1].fingerprint)
    end

    it 'evidence contains receiver, method, and constant details' do
      site = build_site(receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock)
      finding = rule.analyze(call_sites: [site]).first
      evidence = finding.evidence.first

      expect(evidence.source).to eq('Mutex#lock')
      expect(evidence.message).to include('block the thread')
      expect(evidence.details).to include(
        receiver: 'mutex',
        method: 'lock',
        constant: 'Mutex'
      )
    end
  end

  # ── Adapter resilience ────────────────────────────────────────────────
  describe 'adapter resilience' do
    it 'degrades to normal matching when workspace lookup raises' do
      allow(workspace).to receive(:semantic_index).and_raise(StandardError.new('boom'))

      site = build_site(receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock)
      expect(rule.analyze(call_sites: [site]).size).to eq(1)
    end

    it 'degrades to normal matching when resolve_constant raises' do
      allow(semantic_index).to receive(:resolve_constant).and_raise(StandardError.new('boom'))

      site = build_site(receiver_source: 'mutex', receiver_constant: 'Mutex', method_name: :lock)
      expect(rule.analyze(call_sites: [site]).size).to eq(1)
    end

    it 'returns empty array when ancestors_of raises' do
      allow(workspace).to receive(:ancestors_of).and_raise(StandardError.new('boom'))

      site = build_site(
        receiver_source: nil, receiver_constant: nil, method_name: :synchronize,
        enclosing_symbol: 'Worker#perform'
      )
      expect(rule.analyze(call_sites: [site])).to eq([])
    end
  end
end
