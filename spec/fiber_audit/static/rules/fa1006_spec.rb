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
    it 'keeps rule identity and advisory severity with a generic constructor title' do
      expect(described_class.id).to eq('FA1006')
      expect(described_class.severity).to eq(:low)
      expect(described_class.default_confidence).to eq(:high)
      expect(described_class.title).to eq('Direct socket construction')
      expect(described_class.category).to eq(:network)
      expect(described_class.description).to include('inventory-only allocation')
    end

    it 'defines metadata for every shared socket semantic' do
      expect(described_class::CATEGORY_METADATA.keys).to contain_exactly(
        :socket_allocation,
        :socket_resolve_connect,
        :socket_local_connect,
        :socket_constructor_unknown
      )
    end
  end

  describe '#analyze' do
    context 'with exact socket constants' do
      %w[TCPSocket TCPServer UDPSocket UNIXSocket UNIXServer Socket IPSocket].each do |const|
        it "matches #{const}.new" do
          cs = build_call_site(receiver_source: const, receiver_constant: const, method_name: :new)
          findings = rule.analyze(call_sites: [cs])

          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("#{const}.new")
          expect(findings.first.rule_id).to eq('FA1006')
        end
      end
    end

    it 'distinguishes allocation, endpoint setup, local connection, and unknown subclass constructors' do
      cases = {
        'Socket' => [:socket_allocation, 'Direct socket allocation', false, true, nil],
        'TCPSocket' => [:socket_resolve_connect, 'Direct socket endpoint setup', true, false, :address_resolve],
        'UNIXSocket' => [:socket_local_connect, 'Direct local-socket connection', true, false, nil]
      }

      cases.each do |constant, (semantic, title, wait_possible, inventory_only, capability)|
        finding = rule.analyze(call_sites: [build_call_site(receiver_source: constant,
                                                            receiver_constant: constant)]).first
        details = finding.evidence.first.details
        expect(finding.operation).to eq("#{constant}.new")
        expect(finding.title).to eq(title)
        expect(details).to include(
          semantic: semantic,
          wait_possible: wait_possible,
          inventory_only: inventory_only,
          scheduler_capability: capability
        )
      end

      allow(semantic_index).to receive(:ancestors_of)
        .with('Project::ClientSocket')
        .and_return(%w[IPSocket Object])
      subclass = rule.analyze(call_sites: [build_call_site(
        receiver_source: 'Project::ClientSocket',
        receiver_constant: 'Project::ClientSocket'
      )]).first
      expect(subclass.title).to eq('Direct socket subclass construction')
      expect(subclass.evidence.first.details[:semantic]).to eq(:socket_constructor_unknown)
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
        expect(rule.analyze(call_sites: [build_call_site(method_name: :open)])).to be_empty
      end

      it 'does not match TCPServer.accept' do
        cs = build_call_site(receiver_source: 'TCPServer', receiver_constant: 'TCPServer', method_name: :accept)
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end
    end

    context 'with unrelated constants' do
      %w[String Array Hash Object Thread IO].each do |const|
        it "does not match #{const}.new" do
          cs = build_call_site(receiver_source: const, receiver_constant: const, method_name: :new)
          expect(rule.analyze(call_sites: [cs])).to be_empty
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

        cs = build_call_site(receiver_source: 'TCPSocket', receiver_constant: 'TCPSocket', method_name: :new,
                             nesting: [])
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end
    end

    context 'with adapter failure' do
      it 'does not raise when semantic_index.ancestors_of raises' do
        allow(semantic_index).to receive(:ancestors_of).and_raise(StandardError.new('adapter error'))
        cs = build_call_site(receiver_source: 'CustomSocket', receiver_constant: 'CustomSocket', method_name: :new)

        expect { rule.analyze(call_sites: [cs]) }.not_to raise_error
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end

      it 'does not raise when semantic_index.resolve_constant raises' do
        allow(semantic_index).to receive(:resolve_constant).and_raise(StandardError.new('adapter error'))
        cs = build_call_site(receiver_source: 'TCPSocket', receiver_constant: 'TCPSocket', method_name: :new)

        expect { rule.analyze(call_sites: [cs]) }.not_to raise_error
      end

      it 'does not fabricate subclass matches when ancestors lookup fails' do
        allow(semantic_index).to receive(:ancestors_of).and_raise(StandardError)
        cs = build_call_site(receiver_source: 'MaybeSocket', receiver_constant: 'MaybeSocket', method_name: :new)

        expect(rule.analyze(call_sites: [cs])).to be_empty
      end
    end

    context 'with nil receiver_constant' do
      it 'does not match' do
        expect(rule.analyze(call_sites: [build_call_site(receiver_constant: nil)])).to be_empty
      end
    end

    context 'advisory severity (no context escalation)' do
      %i[request rake_task middleware job].each do |context|
        it "stays :low in #{context} context" do
          finding = rule.analyze(call_sites: [build_call_site(execution_context: context)]).first
          expect(finding.severity).to eq(:low)
        end
      end
    end

    context 'with configuration override' do
      let(:configuration) do
        instance_double(FiberAudit::Configuration, severity_override: :medium, rule_enabled?: true)
      end

      it 'applies configuration override without context ceiling' do
        finding = rule.analyze(call_sites: [build_call_site(execution_context: :request)]).first
        expect(finding.severity).to eq(:medium)
      end
    end

    context 'confidence' do
      it 'inherits confidence from call site' do
        finding = rule.analyze(call_sites: [build_call_site(confidence: :high)]).first
        expect(finding.confidence).to eq(:high)
      end

      it 'preserves low confidence from call site' do
        finding = rule.analyze(call_sites: [build_call_site(confidence: :low)]).first
        expect(finding.confidence).to eq(:low)
      end
    end

    context 'finding fields' do
      it 'preserves identity while narrowing endpoint-setup evidence' do
        finding = rule.analyze(call_sites: [build_call_site(
          path: 'app/socket.rb',
          line: 10,
          column: 2,
          receiver_source: 'TCPSocket',
          receiver_constant: 'TCPSocket',
          enclosing_symbol: 'SocketHandler#connect',
          execution_context: :request
        )]).first

        expect(finding.rule_id).to eq('FA1006')
        expect(finding.title).to eq('Direct socket endpoint setup')
        expect(finding.category).to eq(:network)
        expect(finding.severity).to eq(:low)
        expect(finding.confidence).to eq(:high)
        expect(finding.operation).to eq('TCPSocket.new')
        expect(finding.execution_context).to eq(:request)
        expect(finding.symbol).to eq('SocketHandler#connect')
        expect(finding.location.path).to eq('app/socket.rb')
        expect(finding.location.line).to eq(10)
        expect(finding.location.column).to eq(2)
        expect(finding.message).to eq(
          'This constructor may resolve an address and establish a network endpoint, requiring ' \
          'scheduler cooperation from address-resolution and I/O hooks.'
        )
        expect(finding.remediation).to include('Verify address_resolve')
        expect(finding.evidence.first.message).to eq('Matched TCPSocket.new (socket_resolve_connect)')
      end
    end

    context 'fingerprint' do
      it 'generates deterministic fingerprint' do
        cs1 = build_call_site(path: 'test.rb', line: 1, enclosing_symbol: 'foo')
        cs2 = build_call_site(path: 'test.rb', line: 1, enclosing_symbol: 'foo')

        expect(rule.analyze(call_sites: [cs1]).first.fingerprint)
          .to eq(rule.analyze(call_sites: [cs2]).first.fingerprint)
      end

      it 'keeps fingerprints stable when only the line changes' do
        cs1 = build_call_site(path: 'test.rb', line: 1)
        cs2 = build_call_site(path: 'test.rb', line: 2)

        expect(rule.analyze(call_sites: [cs1]).first.fingerprint)
          .to eq(rule.analyze(call_sites: [cs2]).first.fingerprint)
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
        expect(rule.analyze(call_sites: result.call_sites)).to be_empty
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
      cs = build_call_site(receiver_source: 'CustomSocket', receiver_constant: 'CustomSocket')
      findings = rule.analyze(call_sites: [cs])
      expect(findings.size).to eq(1)
      expect(findings.first.operation).to eq('CustomSocket.new')
    end
  end
end
