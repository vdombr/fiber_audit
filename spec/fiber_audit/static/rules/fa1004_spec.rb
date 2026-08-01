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
      it 'emits a finding with request context severity' do
        cs = build_call_site(method_name: :thread_variable_get, execution_context: :request)
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:critical)
        expect(findings.first.confidence).to eq(:high)
        expect(findings.first.operation).to eq('Thread.thread_variable_get')
      end

      it 'emits a finding with rake context severity' do
        cs = build_call_site(method_name: :thread_variable_get, execution_context: :rake_task)
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:high)
      end
    end

    context 'thread_variable_set on Thread.current' do
      it 'emits a finding with request context severity' do
        cs = build_call_site(method_name: :thread_variable_set, execution_context: :request)
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:critical)
        expect(findings.first.operation).to eq('Thread.thread_variable_set')
      end

      it 'emits a finding with rake context severity' do
        cs = build_call_site(method_name: :thread_variable_set, execution_context: :rake_task)
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:high)
      end
    end

    context 'Thread.current[] (index read)' do
      it 'emits a finding with request context severity' do
        cs = build_call_site(method_name: :[], execution_context: :request)
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:critical)
        expect(findings.first.confidence).to eq(:high)
        expect(findings.first.operation).to eq('Thread.current.[]')
      end

      it 'emits a finding with rake context severity' do
        cs = build_call_site(method_name: :[], execution_context: :rake_task)
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'Thread.current[]= (index write)' do
      it 'emits a finding with request context severity' do
        cs = build_call_site(method_name: :[]=, execution_context: :request)
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:critical)
        expect(findings.first.operation).to eq('Thread.current.[]=')
      end

      it 'emits a finding with rake context severity' do
        cs = build_call_site(method_name: :[]=, execution_context: :rake_task)
        findings = rule.analyze(call_sites: [cs])

        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
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
        findings = rule.analyze(call_sites: [cs])

        expect(findings).to be_empty
      end

      it 'skips arbitrary methods on Thread.current' do
        cs = build_call_site(method_name: :some_other_method)
        findings = rule.analyze(call_sites: [cs])

        expect(findings).to be_empty
      end

      it 'skips direct Thread class calls' do
        cs = build_call_site(
          method_name: :thread_variable_get,
          receiver_source: 'Thread',
          receiver_constant: 'Thread'
        )
        findings = rule.analyze(call_sites: [cs])

        expect(findings).to be_empty
      end

      it 'skips workspace-shadowed Thread' do
        shadowed_constant = Struct.new(:name, :path).new('Thread', '/workspace/lib/thread.rb')
        allow(workspace).to receive(:resolve_constant).and_return(shadowed_constant)

        cs = build_call_site(method_name: :thread_variable_get)
        findings = rule.analyze(call_sites: [cs])

        expect(findings).to be_empty
      end

      it 'handles adapter errors gracefully' do
        allow(workspace).to receive(:resolve_constant).and_raise(StandardError, 'adapter error')

        cs = build_call_site(method_name: :thread_variable_get)
        expect { rule.analyze(call_sites: [cs]) }.not_to raise_error
      end
    end

    context 'finding fields' do
      it 'includes all required fields' do
        cs = build_call_site(method_name: :thread_variable_get, execution_context: :request)
        findings = rule.analyze(call_sites: [cs])
        finding = findings.first

        expect(finding.rule_id).to eq('FA1004')
        expect(finding.title).to eq('Thread-local state in fiber code')
        expect(finding.category).to eq(:thread_local)
        expect(finding.message).to eq('Thread-local state may be shared across fibers and leak request-local data.')
        expect(finding.remediation).to eq(
          'Use fiber-local or framework-provided request-local state ' \
          'instead of Thread thread variables.'
        )
        expect(finding.symbol).to eq('User#process')
        expect(finding.execution_context).to eq(:request)
        expect(finding.location).to be_a(FiberAudit::Location)
        expect(finding.evidence).not_to be_empty
      end

      it 'generates a stable fingerprint' do
        cs1 = build_call_site(method_name: :thread_variable_get, execution_context: :request)
        cs2 = build_call_site(method_name: :thread_variable_get, execution_context: :request)

        finding1 = rule.analyze(call_sites: [cs1]).first
        finding2 = rule.analyze(call_sites: [cs2]).first

        expect(finding1.fingerprint).to eq(finding2.fingerprint)
        expect(finding1.fingerprint).to be_a(String)
        expect(finding1.fingerprint.length).to eq(64) # SHA256 hex digest
      end
    end

    context 'confidence' do
      it 'always reports high confidence' do
        cs1 = build_call_site(method_name: :thread_variable_get)
        cs2 = build_call_site(method_name: :[])
        cs3 = build_call_site(method_name: :[]=)

        findings = rule.analyze(call_sites: [cs1, cs2, cs3])

        expect(findings.all? { |f| f.confidence == :high }).to be true
      end
    end
  end
end
