# frozen_string_literal: true

require 'fiber_audit'
require 'fiber_audit/static/rules/direct_socket'

RSpec.describe FiberAudit::Static::Rules::DirectSocket do
  def build_call_site(overrides = {})
    defaults = {
      path: 'test.rb',
      line: 1,
      column: 0,
      receiver_source: 'TCPSocket',
      receiver_constant: 'TCPSocket',
      method_name: :new,
      arguments: [],
      enclosing_symbol: nil,
      nesting: [],
      execution_context: :unknown,
      resolution: 'TCPSocket.new',
      confidence: :high
    }
    FiberAudit::Static::CallSite.new(**defaults, **overrides)
  end

  let(:semantic_index) { double('semantic_index') }
  let(:workspace) { double('workspace', semantic_index: semantic_index) }
  let(:context_resolver) { double('context_resolver') }
  let(:configuration) do
    instance_double(FiberAudit::Configuration,
                    severity_override: nil,
                    rule_enabled?: true)
  end
  let(:rule) do
    described_class.new(
      workspace: workspace,
      context_resolver: context_resolver,
      configuration: configuration
    )
  end

  before do
    allow(semantic_index).to receive(:resolve_constant).and_return(nil)
    allow(semantic_index).to receive(:ancestors_of).and_return([])
  end

  describe 'metadata' do
    it 'has correct id' do
      expect(described_class.id).to eq('FA1006')
    end

    it 'has correct severity' do
      expect(described_class.severity).to eq(:low)
    end

    it 'has correct default_confidence' do
      expect(described_class.default_confidence).to eq(:high)
    end

    it 'has correct title' do
      expect(described_class.title).to eq('Direct socket creation')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:network)
    end
  end

  describe '#analyze' do
    context 'with exact socket constants' do
      %w[TCPSocket TCPServer UDPSocket UNIXSocket UNIXServer Socket IPSocket].each do |const|
        it "matches #{const}.new" do
          cs = build_call_site(
            receiver_source: const,
            receiver_constant: const,
            method_name: :new
          )
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("#{const}.new")
          expect(findings.first.rule_id).to eq('FA1006')
        end
      end
    end

    context 'with IPSocket subclass' do
      it 'matches MyCustomSocket.new when ancestors include IPSocket' do
        allow(semantic_index).to receive(:ancestors_of)
          .with('MyCustomSocket')
          .and_return(%w[IPSocket Object BasicObject])

        cs = build_call_site(
          receiver_source: 'MyCustomSocket',
          receiver_constant: 'MyCustomSocket',
          method_name: :new,
          path: 'app/socket.rb',
          line: 5
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('MyCustomSocket.new')
      end
    end

    context 'with wrong method' do
      it 'does not match TCPSocket.open' do
        cs = build_call_site(method_name: :open)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not match TCPServer.accept' do
        cs = build_call_site(
          receiver_source: 'TCPServer',
          receiver_constant: 'TCPServer',
          method_name: :accept
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with unrelated constants' do
      %w[String Array Hash Object Thread IO].each do |const|
        it "does not match #{const}.new" do
          cs = build_call_site(
            receiver_source: const,
            receiver_constant: const,
            method_name: :new
          )
          findings = rule.analyze(call_sites: [cs])
          expect(findings).to be_empty
        end
      end
    end

    context 'with shadowed constants' do
      it 'does not match when resolve_constant reports workspace declaration' do
        shadow_const = FiberAudit::Static::SemanticIndex::Constant.new(
          name: 'TCPSocket',
          path: 'app/lib/tcp_socket.rb',
          line: 1
        )
        allow(semantic_index).to receive(:resolve_constant)
          .with('TCPSocket', nesting: [])
          .and_return(shadow_const)

        cs = build_call_site(
          receiver_source: 'TCPSocket',
          receiver_constant: 'TCPSocket',
          method_name: :new,
          nesting: []
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with adapter failure' do
      it 'does not raise when semantic_index.ancestors_of raises' do
        allow(semantic_index).to receive(:ancestors_of).and_raise(StandardError.new('adapter error'))

        cs = build_call_site(
          receiver_source: 'CustomSocket',
          receiver_constant: 'CustomSocket',
          method_name: :new
        )
        expect { rule.analyze(call_sites: [cs]) }.not_to raise_error
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not raise when semantic_index.resolve_constant raises' do
        allow(semantic_index).to receive(:resolve_constant).and_raise(StandardError.new('adapter error'))

        cs = build_call_site(
          receiver_source: 'TCPSocket',
          receiver_constant: 'TCPSocket',
          method_name: :new
        )
        expect { rule.analyze(call_sites: [cs]) }.not_to raise_error
      end

      it 'does not fabricate subclass matches when ancestors lookup fails' do
        allow(semantic_index).to receive(:ancestors_of).and_raise(StandardError)

        cs = build_call_site(
          receiver_source: 'MaybeSocket',
          receiver_constant: 'MaybeSocket',
          method_name: :new
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with nil receiver_constant' do
      it 'does not match' do
        cs = build_call_site(receiver_constant: nil)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'advisory severity (no context escalation)' do
      it 'stays :low in :request context (no escalation)' do
        cs = build_call_site(execution_context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end

      it 'stays :low in :rake_task context' do
        cs = build_call_site(execution_context: :rake_task)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end

      it 'stays :low in :middleware context (no escalation)' do
        cs = build_call_site(execution_context: :middleware)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end

      it 'stays :low in :job context (no escalation)' do
        cs = build_call_site(execution_context: :job)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end
    end

    context 'with configuration override' do
      let(:configuration) do
        instance_double(FiberAudit::Configuration, severity_override: :medium, rule_enabled?: true)
      end

      it 'applies configuration override without context ceiling' do
        cs = build_call_site(execution_context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'confidence' do
      it 'inherits confidence from call site' do
        cs = build_call_site(confidence: :high)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:high)
      end

      it 'preserves low confidence from call site' do
        cs = build_call_site(confidence: :low)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:low)
      end
    end

    context 'operation field' do
      it 'uses canonical format: constant.new' do
        cs = build_call_site(
          receiver_source: 'TCPSocket',
          receiver_constant: 'TCPSocket'
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.operation).to eq('TCPSocket.new')
      end

      it 'retains subclass name in operation' do
        allow(semantic_index).to receive(:ancestors_of)
          .with('MySocket')
          .and_return(%w[IPSocket Object])

        cs = build_call_site(
          receiver_source: 'MySocket',
          receiver_constant: 'MySocket'
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.operation).to eq('MySocket.new')
      end
    end

    context 'finding fields' do
      it 'populates all required fields correctly' do
        cs = build_call_site(
          path: 'app/socket.rb',
          line: 10,
          column: 2,
          receiver_source: 'TCPSocket',
          receiver_constant: 'TCPSocket',
          method_name: :new,
          enclosing_symbol: 'SocketHandler#connect',
          execution_context: :request,
          confidence: :high
        )
        findings = rule.analyze(call_sites: [cs])
        finding = findings.first

        expect(finding.rule_id).to eq('FA1006')
        expect(finding.title).to eq('Direct socket creation')
        expect(finding.category).to eq(:network)
        expect(finding.severity).to eq(:low)
        expect(finding.confidence).to eq(:high)
        expect(finding.operation).to eq('TCPSocket.new')
        expect(finding.execution_context).to eq(:request)
        expect(finding.symbol).to eq('SocketHandler#connect')
        expect(finding.location.path).to eq('app/socket.rb')
        expect(finding.location.line).to eq(10)
        expect(finding.location.column).to eq(2)
        expect(finding.message).to include('bypass scheduler-aware networking')
        expect(finding.remediation).to include('scheduler-aware networking APIs')
        expect(finding.evidence.size).to eq(1)
        expect(finding.evidence.first.source).to eq('static_analysis')
        expect(finding.evidence.first.details[:receiver_constant]).to eq('TCPSocket')
        expect(finding.evidence.first.details[:method]).to eq(:new)
      end
    end

    context 'fingerprint' do
      it 'generates deterministic fingerprint' do
        cs1 = build_call_site(path: 'test.rb', line: 1, enclosing_symbol: 'foo')
        cs2 = build_call_site(path: 'test.rb', line: 1, enclosing_symbol: 'foo')

        findings1 = rule.analyze(call_sites: [cs1])
        findings2 = rule.analyze(call_sites: [cs2])

        expect(findings1.first.fingerprint).to eq(findings2.first.fingerprint)
      end

      it 'keeps fingerprints stable when only the line changes' do
        cs1 = build_call_site(path: 'test.rb', line: 1)
        cs2 = build_call_site(path: 'test.rb', line: 2)

        findings1 = rule.analyze(call_sites: [cs1])
        findings2 = rule.analyze(call_sites: [cs2])

        expect(findings1.first.fingerprint).to eq(findings2.first.fingerprint)
      end
    end
  end

  describe 'fixtures' do
    let(:extractor) do
      FiberAudit::Static::CallSiteExtractor.new(
        files: [fixture_file],
        semantic_index: nil
      )
    end
    let(:result) { extractor.call }

    context 'positive fixture' do
      let(:fixture_file) { fixtures_path('rules', 'FA1006', 'positive.rb') }

      it 'matches all seven exact socket constants' do
        findings = rule.analyze(call_sites: result.call_sites)
        expect(findings.size).to eq(7)

        operations = findings.map(&:operation).sort
        expected = %w[
          IPSocket.new
          Socket.new
          TCPServer.new
          TCPSocket.new
          UDPSocket.new
          UNIXServer.new
          UNIXSocket.new
        ]
        expect(operations).to eq(expected)
      end

      it 'all findings have correct rule_id' do
        findings = rule.analyze(call_sites: result.call_sites)
        expect(findings.map(&:rule_id).uniq).to eq(['FA1006'])
      end

      it 'all findings have network category' do
        findings = rule.analyze(call_sites: result.call_sites)
        expect(findings.map(&:category).uniq).to eq([:network])
      end
    end

    context 'negative fixture' do
      let(:fixture_file) { fixtures_path('rules', 'FA1006', 'negative.rb') }

      it 'does not match any call sites' do
        findings = rule.analyze(call_sites: result.call_sites)
        expect(findings).to be_empty
      end
    end
  end

  describe 'workspace as semantic_index' do
    let(:ws) do
      double('workspace_semantic_index').tap do |d|
        allow(d).to receive(:ancestors_of).with('CustomSocket').and_return(%w[IPSocket Object])
        allow(d).to receive(:resolve_constant).and_return(nil)
      end
    end
    let(:rule) do
      described_class.new(
        workspace: ws,
        context_resolver: context_resolver,
        configuration: configuration
      )
    end

    it 'uses workspace directly when it responds to ancestors_of' do
      cs = build_call_site(
        receiver_source: 'CustomSocket',
        receiver_constant: 'CustomSocket'
      )
      findings = rule.analyze(call_sites: [cs])
      expect(findings.size).to eq(1)
      expect(findings.first.operation).to eq('CustomSocket.new')
    end
  end
end
