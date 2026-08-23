# frozen_string_literal: true

require 'fiber_audit/static/rules/thread_current_state'
require 'fiber_audit/static/call_site'
require 'fiber_audit/configuration'
require 'fiber_audit/findings/location'

RSpec.describe FiberAudit::Static::Rules::ThreadCurrentState do
  let(:workspace) { instance_double('Workspace', resolve_constant: nil, root: '/workspace') }
  let(:context_resolver) { instance_double('ContextResolver') }
  let(:configuration) do
    instance_double(FiberAudit::Configuration, severity_override: nil)
  end
  let(:rule) do
    described_class.new(
      workspace: workspace,
      context_resolver: context_resolver,
      configuration: configuration
    )
  end

  def build_call_site(**overrides)
    defaults = {
      path: 'app/models/user.rb',
      line: 10,
      column: 5,
      receiver_source: 'Thread.current',
      receiver_constant: 'Thread',
      method_name: :thread_variable_get,
      arguments: [],
      enclosing_symbol: 'User#process',
      nesting: ['User'],
      execution_context: :request,
      resolution: 'Thread.current.thread_variable_get',
      confidence: :high
    }
    FiberAudit::Static::CallSite.new(**defaults, **overrides)
  end

  describe '#analyze' do
    context 'thread_variable_get on Thread.current' do
      it 'emits a medium finding in request context' do
        site = build_call_site(method_name: :thread_variable_get, execution_context: :request)
        finding = rule.analyze(call_sites: [site]).first

        expect(finding.severity).to eq(:medium)
        expect(finding.confidence).to eq(:high)
        expect(finding.operation).to eq('Thread.thread_variable_get')
      end

      it 'emits a medium finding in rake context' do
        site = build_call_site(method_name: :thread_variable_get, execution_context: :rake_task)
        finding = rule.analyze(call_sites: [site]).first

        expect(finding.severity).to eq(:medium)
      end
    end

    context 'thread_variable_set on Thread.current' do
      it 'emits a medium finding in request context' do
        site = build_call_site(method_name: :thread_variable_set, execution_context: :request)
        finding = rule.analyze(call_sites: [site]).first

        expect(finding.severity).to eq(:medium)
        expect(finding.operation).to eq('Thread.thread_variable_set')
      end

      it 'emits a medium finding in rake context' do
        site = build_call_site(method_name: :thread_variable_set, execution_context: :rake_task)
        finding = rule.analyze(call_sites: [site]).first

        expect(finding.severity).to eq(:medium)
      end
    end

    context 'Thread.current[] (index read) - NOT detected' do
      it 'does not emit a finding for index read' do
        cs = build_call_site(method_name: :[], execution_context: :request)
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end
    end

    context 'Thread.current[]= (index write) - NOT detected' do
      it 'does not emit a finding for index write' do
        cs = build_call_site(method_name: :[]=, execution_context: :request)
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end
    end

    context 'thread_variable on Thread instance (not Thread.current)' do
      it 'emits a finding when receiver_constant is Thread' do
        cs = build_call_site(
          method_name: :thread_variable_get,
          receiver_source: 'my_thread',
          receiver_constant: 'Thread'
        )
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Thread.thread_variable_get')
      end
    end

    context 'negative cases' do
      it 'skips ActiveSupport::CurrentAttributes' do
        cs = build_call_site(
          method_name: :thread_variable_get,
          receiver_source: 'ActiveSupport::CurrentAttributes',
          receiver_constant: 'ActiveSupport::CurrentAttributes'
        )
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end

      it 'skips arbitrary methods on Thread.current' do
        cs = build_call_site(method_name: :some_other_method)
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end

      it 'skips direct Thread class calls' do
        cs = build_call_site(
          method_name: :thread_variable_get,
          receiver_source: 'Thread',
          receiver_constant: 'Thread'
        )
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end

      it 'skips workspace-shadowed Thread' do
        shadowed_constant = Struct.new(:name, :path).new('Thread', '/workspace/lib/thread.rb')
        allow(workspace).to receive(:resolve_constant).and_return(shadowed_constant)

        cs = build_call_site(method_name: :thread_variable_get)
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end

      it 'handles adapter errors gracefully' do
        allow(workspace).to receive(:resolve_constant).and_raise(StandardError, 'adapter error')

        cs = build_call_site(method_name: :thread_variable_get)
        expect { rule.analyze(call_sites: [cs]) }.not_to raise_error
      end
    end

    it 'uses medium severity without execution-context escalation' do
      expect(described_class.default_severity).to eq(:medium)

      %i[request middleware callback job rake_task unknown].each do |context|
        get = build_call_site(method_name: :thread_variable_get, execution_context: context)
        set = build_call_site(method_name: :thread_variable_set, execution_context: context)
        expect(rule.analyze(call_sites: [get, set]).map(&:severity)).to eq(%i[medium medium])
      end
    end

    context 'with configuration override' do
      let(:configuration) do
        instance_double(FiberAudit::Configuration, severity_override: :high)
      end

      it 'uses the explicit override without context escalation' do
        finding = rule.analyze(call_sites: [build_call_site(execution_context: :request)]).first
        expect(finding.severity).to eq(:high)
      end
    end

    context 'finding fields' do
      it 'states possible shared-state exposure without claiming request-sensitive leakage' do
        finding = rule.analyze(call_sites: [build_call_site(execution_context: :request)]).first

        expect(finding.rule_id).to eq('FA1004')
        expect(finding.title).to eq('Thread-variable access shared across fibers')
        expect(finding.category).to eq(:thread_local)
        expect(finding.message).to eq(
          'Thread variables are visible to fibers sharing a thread. This access may expose mutable ' \
          'state across concurrent work, but static analysis does not establish request-sensitive leakage.'
        )
        expect(finding.remediation).to eq(
          'Prefer fiber-local storage (Fiber[:key]) or framework-provided ' \
          'request-local state over thread_variable_get/set.'
        )
        expect(finding.symbol).to eq('User#process')
        expect(finding.execution_context).to eq(:request)
        expect(finding.location).to be_a(FiberAudit::Location)
        expect(finding.evidence.first.message).to eq(
          'Matched thread-variable access via thread_variable_get'
        )
      end

      it 'generates a stable fingerprint' do
        cs1 = build_call_site(method_name: :thread_variable_get, execution_context: :request)
        cs2 = build_call_site(method_name: :thread_variable_get, execution_context: :request)

        finding1 = rule.analyze(call_sites: [cs1]).first
        finding2 = rule.analyze(call_sites: [cs2]).first

        expect(finding1.fingerprint).to eq(finding2.fingerprint)
        expect(finding1.fingerprint).to be_a(String)
        expect(finding1.fingerprint.length).to eq(64)
      end
    end

    context 'confidence' do
      it 'always reports high confidence for thread variable operations' do
        cs1 = build_call_site(method_name: :thread_variable_get)
        cs2 = build_call_site(method_name: :thread_variable_set)

        findings = rule.analyze(call_sites: [cs1, cs2])

        expect(findings.all? { |finding| finding.confidence == :high }).to be true
      end
    end

    context 'evidence' do
      it 'includes operation and receiver in evidence details' do
        cs = build_call_site(method_name: :thread_variable_get, execution_context: :request)
        evidence = rule.analyze(call_sites: [cs]).first.evidence.first

        expect(evidence.source).to eq('Thread.current')
        expect(evidence.message).to eq('Matched thread-variable access via thread_variable_get')
        expect(evidence.details[:operation]).to eq('Thread.thread_variable_get')
        expect(evidence.details[:receiver]).to eq('Thread.current')
      end
    end

    it 'does not retain thread-variable keys or values in finding evidence' do
      secret_key = 'private-thread-key-sentinel'
      secret_value = 'private-thread-value-sentinel'
      site = build_call_site(arguments: [secret_key, secret_value])

      finding = rule.analyze(call_sites: [site]).first
      serialized = finding.to_h.to_s

      expect(serialized).not_to include(secret_key, secret_value)
      expect(finding.evidence.first.details.keys).to contain_exactly(:operation, :receiver)
    end
  end
end
