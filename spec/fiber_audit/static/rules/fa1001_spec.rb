# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/rules/blocking_subprocess'
require 'fiber_audit/static/call_site'

RSpec.describe FiberAudit::Static::Rules::BlockingSubprocess do
  let(:workspace) do
    instance_double('FiberAudit::Workspace', semantic_index: semantic_index)
  end
  let(:semantic_index) { instance_double('FiberAudit::Static::SemanticIndex') }
  let(:configuration) do
    instance_double('FiberAudit::Configuration', severity_override: nil)
  end
  let(:context_resolver) do
    instance_double('FiberAudit::Static::ExecutionContextResolver')
  end

  subject(:rule) do
    described_class.new(
      workspace: workspace,
      context_resolver: context_resolver,
      configuration: configuration
    )
  end

  before do
    allow(semantic_index).to receive(:resolve_constant).and_return(nil)
  end

  def make_call_site(receiver_constant:, method_name:, execution_context: :request,
                     confidence: nil, path: 'app/models/user.rb', line: 10,
                     enclosing_symbol: 'User#process', nesting: ['User'])
    conf = confidence || (receiver_constant ? :high : :unknown)

    FiberAudit::Static::CallSite.new(
      path: path,
      line: line,
      column: 4,
      receiver_source: receiver_constant,
      receiver_constant: receiver_constant,
      method_name: method_name,
      arguments: [],
      enclosing_symbol: enclosing_symbol,
      nesting: nesting,
      execution_context: execution_context,
      resolution: receiver_constant ? "#{receiver_constant}.#{method_name}" : nil,
      confidence: conf
    )
  end

  describe 'metadata' do
    it 'has correct id' do
      expect(described_class.id).to eq('FA1001')
    end

    it 'has correct default severity' do
      expect(described_class.severity).to eq(:high)
    end

    it 'has correct default confidence' do
      expect(described_class.default_confidence).to eq(:high)
    end

    it 'has description' do
      expect(described_class.description).not_to be_empty
    end
  end

  describe '#analyze' do
    context 'with explicit Kernel calls' do
      %i[system exec spawn].each do |method|
        it "detects Kernel.#{method}" do
          cs = make_call_site(receiver_constant: 'Kernel', method_name: method)
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("Kernel.#{method}")
        end
      end
    end

    context 'with Open3 calls' do
      %i[capture2 capture2e capture3 pipeline].each do |method|
        it "detects Open3.#{method}" do
          cs = make_call_site(receiver_constant: 'Open3', method_name: method)
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("Open3.#{method}")
        end
      end
    end

    context 'with IO.popen' do
      it 'detects IO.popen' do
        cs = make_call_site(receiver_constant: 'IO', method_name: :popen)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('IO.popen')
      end
    end

    context 'with Process calls' do
      %i[waitall detach].each do |method|
        it "detects Process.#{method}" do
          cs = make_call_site(receiver_constant: 'Process', method_name: method)
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("Process.#{method}")
        end
      end
    end

    context 'with bare Kernel calls' do
      %i[system exec spawn].each do |method|
        it "detects bare #{method}" do
          cs = make_call_site(receiver_constant: nil, method_name: method, confidence: :unknown)
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("Kernel.#{method}")
          expect(findings.first.confidence).to eq(:unknown)
        end
      end
    end

    context 'with wrong receiver' do
      it 'does not detect CustomKernel.system' do
        cs = make_call_site(receiver_constant: 'CustomKernel', method_name: :system)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect MyOpen3.capture2' do
        cs = make_call_site(receiver_constant: 'MyOpen3', method_name: :capture2)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with wrong method' do
      it 'does not detect Kernel.puts' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :puts)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect Open3.unknown' do
        cs = make_call_site(receiver_constant: 'Open3', method_name: :unknown)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect IO.read' do
        cs = make_call_site(receiver_constant: 'IO', method_name: :read)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect Process.fork' do
        cs = make_call_site(receiver_constant: 'Process', method_name: :fork)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with semantic shadow' do
      it 'does not detect shadowed Kernel' do
        shadow_const = FiberAudit::Static::SemanticIndex::Constant.new(
          name: 'Kernel',
          path: '/app/lib/kernel.rb',
          line: 1
        )
        allow(semantic_index).to receive(:resolve_constant)
          .with('Kernel', nesting: ['User'])
          .and_return(shadow_const)

        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect shadowed Open3' do
        shadow_const = FiberAudit::Static::SemanticIndex::Constant.new(
          name: 'Open3',
          path: '/app/lib/open3.rb',
          line: 1
        )
        allow(semantic_index).to receive(:resolve_constant)
          .with('Open3', nesting: ['User'])
          .and_return(shadow_const)

        cs = make_call_site(receiver_constant: 'Open3', method_name: :capture2)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with adapter error' do
      it 'degrades to normal matching' do
        allow(semantic_index).to receive(:resolve_constant).and_raise(StandardError)
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end
    end

    context 'with severity upgrades' do
      it 'upgrades to critical in request context' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system, execution_context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:critical)
      end

      it 'upgrades to critical in middleware context' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system, execution_context: :middleware)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:critical)
      end

      it 'keeps high in rake_task context' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system, execution_context: :rake_task)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:high)
      end

      it 'keeps high in job context' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system, execution_context: :job)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:high)
      end

      it 'keeps high in unknown context' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system, execution_context: :unknown)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:high)
      end
    end

    context 'with confidence' do
      it 'uses call-site confidence for explicit calls' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system, confidence: :high)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:high)
      end

      it 'uses unknown confidence for bare calls' do
        cs = make_call_site(receiver_constant: nil, method_name: :system, confidence: :unknown)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:unknown)
      end

      it 'uses low confidence when call-site has low' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system, confidence: :low)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:low)
      end
    end

    context 'with finding attributes' do
      let(:cs) { make_call_site(receiver_constant: 'Kernel', method_name: :system) }
      let(:finding) { rule.analyze(call_sites: [cs]).first }

      it 'has correct title' do
        expect(finding.title).to eq('Blocking subprocess call')
      end

      it 'has correct category' do
        expect(finding.category).to eq(:subprocess)
      end

      it 'has correct message' do
        expect(finding.message).to eq('Subprocess operation may block the thread running the fiber scheduler.')
      end

      it 'has correct remediation' do
        expect(finding.remediation).to eq('Move long-running subprocess work outside the request path, or verify scheduler behaviour under load.')
      end

      it 'has non-empty evidence' do
        expect(finding.evidence).not_to be_empty
        expect(finding.evidence.first.source).to eq(:static)
        expect(finding.evidence.first.message).to eq('Matched Kernel.system')
      end

      it 'has correct operation' do
        expect(finding.operation).to eq('Kernel.system')
      end

      it 'has location from call site' do
        expect(finding.location.path).to eq('app/models/user.rb')
        expect(finding.location.line).to eq(10)
      end

      it 'has symbol from call site' do
        expect(finding.symbol).to eq('User#process')
      end

      it 'has execution context from call site' do
        expect(finding.execution_context).to eq(:request)
      end

      it 'has rule_id' do
        expect(finding.rule_id).to eq('FA1001')
      end
    end

    context 'with stable fingerprint' do
      it 'produces same fingerprint across runs' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        finding1 = rule.analyze(call_sites: [cs]).first
        finding2 = rule.analyze(call_sites: [cs]).first
        expect(finding1.fingerprint).to eq(finding2.fingerprint)
      end

      it 'produces different fingerprints for different operations' do
        cs1 = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        cs2 = make_call_site(receiver_constant: 'Kernel', method_name: :exec)
        finding1 = rule.analyze(call_sites: [cs1]).first
        finding2 = rule.analyze(call_sites: [cs2]).first
        expect(finding1.fingerprint).not_to eq(finding2.fingerprint)
      end
    end

    context 'with no semantic index' do
      let(:workspace) { instance_double('FiberAudit::Workspace', semantic_index: nil) }

      it 'still detects matches' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end
    end

    context 'with multiple call sites' do
      it 'detects all matches' do
        cs1 = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        cs2 = make_call_site(receiver_constant: 'Open3', method_name: :capture3)
        cs3 = make_call_site(receiver_constant: 'IO', method_name: :popen)
        findings = rule.analyze(call_sites: [cs1, cs2, cs3])
        expect(findings.size).to eq(3)
      end
    end
  end
end
