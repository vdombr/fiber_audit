# frozen_string_literal: true

require 'fiber_audit/static/rules/io_select'
require 'fiber_audit/static/call_site'
require 'fiber_audit/configuration'

RSpec.describe FiberAudit::Static::Rules::IOSelect do
  let(:semantic_index) { instance_double('FiberAudit::Static::SemanticIndex') }
  let(:workspace) do
    instance_double('FiberAudit::Workspace', semantic_index: semantic_index)
  end
  let(:context_resolver) { instance_double('FiberAudit::Static::ExecutionContextResolver') }
  let(:configuration) do
    instance_double(FiberAudit::Configuration, severity_override: nil)
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

  def build_call_site(overrides = {})
    defaults = {
      path: 'app/models/worker.rb',
      line: 15,
      column: 4,
      receiver_source: 'IO',
      receiver_constant: 'IO',
      method_name: :select,
      arguments: [],
      enclosing_symbol: 'Worker#poll',
      nesting: ['Worker'],
      execution_context: :request,
      resolution: 'IO.select',
      confidence: :high
    }
    FiberAudit::Static::CallSite.new(**defaults, **overrides)
  end

  describe 'metadata' do
    it 'has correct id' do
      expect(described_class.id).to eq('FA1005')
    end

    it 'has correct default severity' do
      expect(described_class.severity).to eq(:medium)
    end

    it 'has correct default confidence' do
      expect(described_class.default_confidence).to eq(:high)
    end

    it 'has correct title' do
      expect(described_class.title).to eq('Explicit IO.select call')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:blocking_io)
    end

    it 'has description' do
      expect(described_class.description).not_to be_empty
    end
  end

  describe '#analyze' do
    context 'with explicit IO.select' do
      it 'detects IO.select' do
        cs = build_call_site(receiver_constant: 'IO')
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('IO.select')
      end

      it 'reports high confidence for explicit IO.select' do
        cs = build_call_site(receiver_constant: 'IO', confidence: :high)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:high)
      end
    end

    context 'with explicit Kernel.select' do
      it 'detects Kernel.select' do
        cs = build_call_site(
          receiver_source: 'Kernel',
          receiver_constant: 'Kernel',
          resolution: 'Kernel.select'
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Kernel.select')
      end
    end

    context 'with bare select call' do
      it 'detects bare select as Kernel.select' do
        cs = build_call_site(
          receiver_source: nil,
          receiver_constant: nil,
          resolution: nil,
          confidence: :unknown
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('Kernel.select')
      end

      it 'retains :unknown confidence for bare select' do
        cs = build_call_site(
          receiver_source: nil,
          receiver_constant: nil,
          resolution: nil,
          confidence: :unknown
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:unknown)
      end
    end

    context 'with wrong receiver' do
      it 'does not detect MyIO.select' do
        cs = build_call_site(receiver_constant: 'MyIO', receiver_source: 'MyIO')
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect CustomKernel.select' do
        cs = build_call_site(receiver_constant: 'CustomKernel', receiver_source: 'CustomKernel')
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with wrong method' do
      it 'does not detect IO.read' do
        cs = build_call_site(receiver_constant: 'IO', method_name: :read)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect Kernel.puts' do
        cs = build_call_site(
          receiver_constant: 'Kernel',
          receiver_source: 'Kernel',
          method_name: :puts
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect IO.copy_stream' do
        cs = build_call_site(receiver_constant: 'IO', method_name: :copy_stream)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with semantic shadow' do
      it 'does not detect shadowed IO' do
        shadow_const = Struct.new(:name, :path, :line).new('IO', '/app/lib/io.rb', 1)
        allow(semantic_index).to receive(:resolve_constant)
          .with('IO', nesting: ['Worker'])
          .and_return(shadow_const)

        cs = build_call_site(receiver_constant: 'IO', nesting: ['Worker'])
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect shadowed Kernel' do
        shadow_const = Struct.new(:name, :path, :line).new('Kernel', '/app/lib/kernel.rb', 1)
        allow(semantic_index).to receive(:resolve_constant)
          .with('Kernel', nesting: ['Worker'])
          .and_return(shadow_const)

        cs = build_call_site(
          receiver_constant: 'Kernel',
          receiver_source: 'Kernel',
          nesting: ['Worker']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with adapter error' do
      it 'degrades gracefully when resolve_constant raises' do
        allow(semantic_index).to receive(:resolve_constant).and_raise(StandardError, 'adapter error')

        cs = build_call_site(receiver_constant: 'IO')
        expect { rule.analyze(call_sites: [cs]) }.not_to raise_error
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end
    end

    context 'with no semantic index' do
      let(:workspace) { instance_double('FiberAudit::Workspace', semantic_index: nil) }

      it 'still detects IO.select' do
        cs = build_call_site(receiver_constant: 'IO')
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end
    end

    context 'with severity' do
      it 'raises to :critical in :request context' do
        cs = build_call_site(execution_context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:critical)
      end

      it 'raises to :critical in :middleware context' do
        cs = build_call_site(execution_context: :middleware)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:critical)
      end

      it 'raises to :critical in :websocket context' do
        cs = build_call_site(execution_context: :websocket)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:critical)
      end

      it 'keeps :medium in :rake_task context' do
        cs = build_call_site(execution_context: :rake_task)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:medium)
      end

      it 'raises to :high in :job context' do
        cs = build_call_site(execution_context: :job)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:high)
      end
    end

    context 'with finding fields' do
      it 'populates all required fields correctly' do
        cs = build_call_site(
          path: 'app/worker.rb',
          line: 42,
          column: 6,
          receiver_source: 'IO',
          receiver_constant: 'IO',
          enclosing_symbol: 'Worker#run',
          execution_context: :request,
          confidence: :high
        )
        findings = rule.analyze(call_sites: [cs])
        finding = findings.first

        expect(finding.rule_id).to eq('FA1005')
        expect(finding.title).to eq('Explicit IO.select call')
        expect(finding.category).to eq(:blocking_io)
        expect(finding.severity).to eq(:critical)
        expect(finding.confidence).to eq(:high)
        expect(finding.operation).to eq('IO.select')
        expect(finding.execution_context).to eq(:request)
        expect(finding.symbol).to eq('Worker#run')
        expect(finding.location.path).to eq('app/worker.rb')
        expect(finding.location.line).to eq(42)
        expect(finding.location.column).to eq(6)
        expect(finding.message).to eq(
          'IO.select may bypass scheduler-aware I/O and block the thread running the fiber scheduler.'
        )
        expect(finding.remediation).to eq(
          'Use scheduler-aware I/O APIs or allow the active Fiber scheduler to manage readiness.'
        )
        expect(finding.evidence.size).to eq(1)
        expect(finding.evidence.first.source).to eq('static_analysis')
        expect(finding.evidence.first.message).to eq('Explicit IO.select: IO.select')
        expect(finding.evidence.first.details[:receiver]).to eq('IO')
        expect(finding.evidence.first.details[:method]).to eq(:select)
      end
    end

    context 'with fingerprint' do
      it 'generates deterministic fingerprint' do
        cs1 = build_call_site(path: 'test.rb', line: 1, enclosing_symbol: 'foo')
        cs2 = build_call_site(path: 'test.rb', line: 1, enclosing_symbol: 'foo')

        f1 = rule.analyze(call_sites: [cs1]).first
        f2 = rule.analyze(call_sites: [cs2]).first

        expect(f1.fingerprint).to eq(f2.fingerprint)
        expect(f1.fingerprint).to be_a(String)
        expect(f1.fingerprint.length).to eq(64)
      end

      it 'generates different fingerprints for different operations' do
        cs1 = build_call_site(receiver_constant: 'IO', path: 'test.rb', line: 1)
        cs2 = build_call_site(
          receiver_constant: 'Kernel',
          receiver_source: 'Kernel',
          path: 'test.rb',
          line: 1
        )

        f1 = rule.analyze(call_sites: [cs1]).first
        f2 = rule.analyze(call_sites: [cs2]).first

        expect(f1.fingerprint).not_to eq(f2.fingerprint)
      end
    end

    context 'with multiple call sites' do
      it 'detects all matching call sites' do
        cs1 = build_call_site(receiver_constant: 'IO')
        cs2 = build_call_site(
          receiver_constant: 'Kernel',
          receiver_source: 'Kernel',
          resolution: 'Kernel.select'
        )
        cs3 = build_call_site(
          receiver_constant: nil,
          receiver_source: nil,
          resolution: nil,
          confidence: :unknown
        )

        findings = rule.analyze(call_sites: [cs1, cs2, cs3])
        expect(findings.size).to eq(3)
        operations = findings.map(&:operation).sort
        expect(operations).to eq(%w[IO.select Kernel.select Kernel.select])
      end

      it 'skips non-matching call sites in mixed input' do
        cs1 = build_call_site(receiver_constant: 'IO')
        cs2 = build_call_site(receiver_constant: 'IO', method_name: :read)
        cs3 = build_call_site(receiver_constant: 'MyIO', receiver_source: 'MyIO')

        findings = rule.analyze(call_sites: [cs1, cs2, cs3])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('IO.select')
      end
    end

    context 'with workspace as direct semantic adapter' do
      let(:workspace) do
        instance_double('FiberAudit::Workspace', semantic_index: nil, resolve_constant: nil)
      end

      it 'falls back to workspace.resolve_constant when semantic_index is nil' do
        allow(workspace).to receive(:resolve_constant)
          .with('IO', nesting: ['Worker'])
          .and_return(nil)

        cs = build_call_site(receiver_constant: 'IO', nesting: ['Worker'])
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end

      it 'skips when workspace.resolve_constant returns non-nil' do
        shadow = Struct.new(:name, :path, :line).new('IO', '/app/lib/io.rb', 1)
        allow(workspace).to receive(:resolve_constant)
          .with('IO', nesting: ['Worker'])
          .and_return(shadow)

        cs = build_call_site(receiver_constant: 'IO', nesting: ['Worker'])
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end
  end
end
