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
      expect(described_class.severity).to eq(:medium)
    end

    it 'has correct default confidence' do
      expect(described_class.default_confidence).to eq(:high)
    end

    it 'has description' do
      expect(described_class.description).not_to be_empty
    end
  end

  describe 'taxonomy' do
    it 'defines OPERATION_CATEGORY for all targets' do
      expect(described_class::OPERATION_CATEGORY).to be_a(Hash)
      expect(described_class::OPERATION_CATEGORY).not_to be_empty
    end

    it 'defines CATEGORY_METADATA for all categories' do
      expect(described_class::CATEGORY_METADATA).to be_a(Hash)
      expect(described_class::CATEGORY_METADATA.keys).to contain_exactly(
        :creation, :replacement, :waiting, :detach, :stream
      )
    end

    it 'assigns info severity to creation operations' do
      expect(described_class::CATEGORY_METADATA[:creation][:severity]).to eq(:info)
    end

    it 'assigns info severity to replacement operations' do
      expect(described_class::CATEGORY_METADATA[:replacement][:severity]).to eq(:info)
    end

    it 'assigns info severity to detach operations' do
      expect(described_class::CATEGORY_METADATA[:detach][:severity]).to eq(:info)
    end

    it 'assigns medium severity to waiting operations' do
      expect(described_class::CATEGORY_METADATA[:waiting][:severity]).to eq(:medium)
    end

    it 'assigns medium severity to stream operations' do
      expect(described_class::CATEGORY_METADATA[:stream][:severity]).to eq(:medium)
    end
  end

  describe '#analyze' do
    context 'with creation operations' do
      it 'detects Kernel.spawn as creation' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :spawn)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Kernel.spawn')
        expect(findings.first.evidence.first.details[:semantic]).to eq(:creation)
      end

      it 'detects Process.spawn as creation' do
        cs = make_call_site(receiver_constant: 'Process', method_name: :spawn)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Process.spawn')
        expect(findings.first.evidence.first.details[:semantic]).to eq(:creation)
      end
    end

    context 'with replacement operations' do
      it 'detects Kernel.exec as replacement' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :exec)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Kernel.exec')
        expect(findings.first.evidence.first.details[:semantic]).to eq(:replacement)
      end

      it 'detects Process.exec as replacement' do
        cs = make_call_site(receiver_constant: 'Process', method_name: :exec)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Process.exec')
        expect(findings.first.evidence.first.details[:semantic]).to eq(:replacement)
      end
    end

    context 'with waiting operations' do
      it 'detects Kernel.system as waiting' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Kernel.system')
        expect(findings.first.evidence.first.details[:semantic]).to eq(:waiting)
      end

      %i[wait wait2 waitpid waitpid2 waitall].each do |method|
        it "detects Process.#{method} as waiting" do
          cs = make_call_site(receiver_constant: 'Process', method_name: method)
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("Process.#{method}")
          expect(findings.first.evidence.first.details[:semantic]).to eq(:waiting)
        end
      end

      it 'detects Process::Status.wait as waiting' do
        cs = make_call_site(receiver_constant: 'Process::Status', method_name: :wait)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Process::Status.wait')
        expect(findings.first.evidence.first.details[:semantic]).to eq(:waiting)
      end

      %i[capture2 capture2e capture3 pipeline].each do |method|
        it "detects Open3.#{method} as waiting" do
          cs = make_call_site(receiver_constant: 'Open3', method_name: method)
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("Open3.#{method}")
          expect(findings.first.evidence.first.details[:semantic]).to eq(:waiting)
        end
      end
    end

    context 'with detach operations' do
      it 'detects Process.detach as detach' do
        cs = make_call_site(receiver_constant: 'Process', method_name: :detach)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Process.detach')
        expect(findings.first.evidence.first.details[:semantic]).to eq(:detach)
      end
    end

    context 'with stream operations' do
      it 'detects IO.popen as stream' do
        cs = make_call_site(receiver_constant: 'IO', method_name: :popen)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('IO.popen')
        expect(findings.first.evidence.first.details[:semantic]).to eq(:stream)
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

    context 'with advisory severity independent of execution context' do
      it 'keeps creation informational in request and rake contexts' do
        request = make_call_site(receiver_constant: 'Kernel', method_name: :spawn, execution_context: :request)
        rake = make_call_site(receiver_constant: 'Process', method_name: :spawn, execution_context: :rake_task)
        expect(rule.analyze(call_sites: [request, rake]).map(&:severity)).to eq(%i[info info])
      end

      it 'keeps replacement informational in request context' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :exec, execution_context: :request)
        expect(rule.analyze(call_sites: [cs]).first.severity).to eq(:info)
      end

      it 'keeps waiting medium in request and job contexts' do
        request = make_call_site(receiver_constant: 'Kernel', method_name: :system, execution_context: :request)
        job = make_call_site(receiver_constant: 'Process', method_name: :wait, execution_context: :job)
        expect(rule.analyze(call_sites: [request, job]).map(&:severity)).to eq(%i[medium medium])
      end

      it 'keeps detach informational and stream medium' do
        detach = make_call_site(receiver_constant: 'Process', method_name: :detach, execution_context: :unknown)
        stream = make_call_site(receiver_constant: 'IO', method_name: :popen, execution_context: :unknown)
        expect(rule.analyze(call_sites: [detach, stream]).map(&:severity)).to eq(%i[info medium])
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
      context 'for waiting category' do
        let(:cs) { make_call_site(receiver_constant: 'Kernel', method_name: :system) }
        let(:finding) { rule.analyze(call_sites: [cs]).first }

        it 'has correct title' do
          expect(finding.title).to eq('Subprocess wait')
        end

        it 'has correct category' do
          expect(finding.category).to eq(:subprocess)
        end

        it 'has correct message' do
          expect(finding.message).to eq(
            'Subprocess waiting requires scheduler process-wait cooperation in a non-blocking Fiber.'
          )
        end

        it 'has correct remediation' do
          expect(finding.remediation).to eq(
            'Verify scheduler process_wait support and runtime progress, or move waits outside the fiber-scheduled path.'
          )
        end

        it 'has non-empty evidence with semantic category' do
          expect(finding.evidence).not_to be_empty
          expect(finding.evidence.first.source).to eq(:static)
          expect(finding.evidence.first.message).to eq('Matched Kernel.system (waiting)')
          expect(finding.evidence.first.details[:semantic]).to eq(:waiting)
        end
      end

      context 'for creation category' do
        let(:cs) { make_call_site(receiver_constant: 'Process', method_name: :spawn) }
        let(:finding) { rule.analyze(call_sites: [cs]).first }

        it 'has correct title' do
          expect(finding.title).to eq('Subprocess creation')
        end

        it 'has correct message' do
          expect(finding.message).to eq(
            'Spawning a subprocess may leave background processes that outlive the fiber scheduler session.'
          )
        end

        it 'has correct remediation' do
          expect(finding.remediation).to eq(
            'Track spawned processes or move subprocess creation outside the fiber-scheduled path.'
          )
        end
      end

      context 'for replacement category' do
        let(:cs) { make_call_site(receiver_constant: 'Kernel', method_name: :exec) }
        let(:finding) { rule.analyze(call_sites: [cs]).first }

        it 'has correct title' do
          expect(finding.title).to eq('Process replacement')
        end

        it 'has correct message' do
          expect(finding.message).to eq(
            'Process replacement via exec replaces the current process image, terminating the fiber scheduler.'
          )
        end
      end

      context 'for detach category' do
        let(:cs) { make_call_site(receiver_constant: 'Process', method_name: :detach) }
        let(:finding) { rule.analyze(call_sites: [cs]).first }

        it 'has correct title' do
          expect(finding.title).to eq('Subprocess detach')
        end

        it 'has correct message' do
          expect(finding.message).to eq(
            'Detaching a subprocess may leave it unmanaged by the fiber scheduler.'
          )
        end
      end

      context 'for stream category' do
        let(:cs) { make_call_site(receiver_constant: 'IO', method_name: :popen) }
        let(:finding) { rule.analyze(call_sites: [cs]).first }

        it 'has correct title' do
          expect(finding.title).to eq('Subprocess pipe stream')
        end

        it 'has correct message' do
          expect(finding.message).to eq(
            'Subprocess pipe I/O requires scheduler cooperation while the stream is open.'
          )
        end
      end

      it 'has location from call site' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        finding = rule.analyze(call_sites: [cs]).first
        expect(finding.location.path).to eq('app/models/user.rb')
        expect(finding.location.line).to eq(10)
      end

      it 'has symbol from call site' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        finding = rule.analyze(call_sites: [cs]).first
        expect(finding.symbol).to eq('User#process')
      end

      it 'has execution context from call site' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        finding = rule.analyze(call_sites: [cs]).first
        expect(finding.execution_context).to eq(:request)
      end

      it 'has rule_id' do
        cs = make_call_site(receiver_constant: 'Kernel', method_name: :system)
        finding = rule.analyze(call_sites: [cs]).first
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
