# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/rules/net_http_in_request'
require 'fiber_audit/static/call_site'
require 'fiber_audit/static/call_site_extractor'

RSpec.describe FiberAudit::Static::Rules::NetHTTPInRequest do
  def build_call_site(overrides = {})
    defaults = {
      path: 'test.rb',
      line: 1,
      column: 0,
      receiver_source: 'Net::HTTP',
      receiver_constant: 'Net::HTTP',
      method_name: :get,
      arguments: [],
      enclosing_symbol: nil,
      nesting: [],
      execution_context: :request,
      resolution: 'Net::HTTP.get',
      confidence: :high
    }
    FiberAudit::Static::CallSite.new(**defaults, **overrides)
  end

  let(:semantic_index) { double('semantic_index') }
  let(:workspace) { double('workspace', semantic_index: semantic_index) }
  let(:context_resolver) { double('context_resolver') }
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

  before do
    allow(semantic_index).to receive(:resolve_constant).and_return(nil)
  end

  describe 'metadata' do
    it 'has correct id' do
      expect(described_class.id).to eq('FA1007')
    end

    it 'has correct default severity' do
      expect(described_class.severity).to eq(:high)
    end

    it 'has correct default_confidence' do
      expect(described_class.default_confidence).to eq(:high)
    end

    it 'has description' do
      expect(described_class.description).not_to be_empty
    end
  end

  describe '#analyze' do
    context 'with Net::HTTP target methods' do
      %i[get get_response start request].each do |method|
        it "detects Net::HTTP.#{method}" do
          cs = build_call_site(
            receiver_source: 'Net::HTTP',
            receiver_constant: 'Net::HTTP',
            method_name: method
          )
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
          expect(findings.first.operation).to eq("Net::HTTP.#{method}")
          expect(findings.first.rule_id).to eq('FA1007')
        end
      end
    end

    context 'with URI.open' do
      it 'detects URI.open with http argument' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"http://example.com"']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('URI.open')
      end

      it 'detects URI.open with https argument' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"https://example.com"']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end

      it 'detects URI.open with no arguments' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: []
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end

      it 'detects URI.open with variable argument' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['url']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end
    end

    context 'with OpenURI.open_uri' do
      it 'detects OpenURI.open_uri' do
        cs = build_call_site(
          receiver_source: 'OpenURI',
          receiver_constant: 'OpenURI',
          method_name: :open_uri,
          arguments: ['"http://example.com"']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.operation).to eq('OpenURI.open_uri')
      end
    end

    context 'with wrong methods (exclusions)' do
      it 'does not detect Net::HTTP.get_print' do
        cs = build_call_site(
          receiver_source: 'Net::HTTP',
          receiver_constant: 'Net::HTTP',
          method_name: :get_print
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect Net::HTTP.post' do
        cs = build_call_site(
          receiver_source: 'Net::HTTP',
          receiver_constant: 'Net::HTTP',
          method_name: :post
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect URI.parse' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :parse
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect URI.open_uri' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open_uri
        )
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end

      it 'does not detect OpenURI.open' do
        cs = build_call_site(
          receiver_source: 'OpenURI',
          receiver_constant: 'OpenURI',
          method_name: :open
        )
        expect(rule.analyze(call_sites: [cs])).to be_empty
      end
    end

    context 'with wrong receiver constants' do
      %w[String Array Hash Object Thread IO MyHTTP CustomURI].each do |const|
        it "does not match #{const}.get" do
          cs = build_call_site(
            receiver_source: const,
            receiver_constant: const,
            method_name: :get
          )
          findings = rule.analyze(call_sites: [cs])
          expect(findings).to be_empty
        end
      end
    end

    context 'with URI/OpenURI non-http scheme arguments' do
      it 'skips URI.open with ftp:// scheme' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"ftp://example.com/file"']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'skips URI.open with file:// scheme' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"file:///tmp/data"']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'skips OpenURI.open_uri with mailto: scheme' do
        cs = build_call_site(
          receiver_source: 'OpenURI',
          receiver_constant: 'OpenURI',
          method_name: :open_uri,
          arguments: ['"mailto:user@example.com"']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with execution context gating' do
      %i[request middleware websocket callback].each do |ctx|
        it "emits in :#{ctx} context" do
          cs = build_call_site(execution_context: ctx)
          findings = rule.analyze(call_sites: [cs])
          expect(findings.size).to eq(1)
        end
      end

      %i[job boot rake test unknown].each do |ctx|
        it "does not emit in :#{ctx} context" do
          cs = build_call_site(execution_context: ctx)
          findings = rule.analyze(call_sites: [cs])
          expect(findings).to be_empty
        end
      end

      it 'does not emit when execution_context is nil' do
        cs = build_call_site(execution_context: nil)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with severity rules' do
      it 'Net::HTTP raises to :critical in :request context' do
        cs = build_call_site(execution_context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:critical)
      end

      it 'Net::HTTP raises to :critical in :middleware context' do
        cs = build_call_site(execution_context: :middleware)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:critical)
      end

      it 'Net::HTTP raises to :critical in :websocket context' do
        cs = build_call_site(execution_context: :websocket)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:critical)
      end

      it 'Net::HTTP keeps :high in :callback context' do
        cs = build_call_site(execution_context: :callback)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:high)
      end

      it 'URI.open has FIXED :medium severity regardless of context' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"http://example.com"'],
          execution_context: :request
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:medium)
      end

      it 'OpenURI.open_uri has FIXED :medium severity in middleware' do
        cs = build_call_site(
          receiver_source: 'OpenURI',
          receiver_constant: 'OpenURI',
          method_name: :open_uri,
          arguments: ['"http://example.com"'],
          execution_context: :middleware
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'with confidence' do
      it 'Net::HTTP has :high confidence' do
        cs = build_call_site(execution_context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:high)
      end

      it 'URI.open has FIXED :low confidence regardless of call site' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"http://example.com"'],
          confidence: :high
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:low)
      end
    end

    context 'with semantic workspace shadow' do
      it 'skips when Net::HTTP is workspace-defined' do
        shadow_const = FiberAudit::Static::SemanticIndex::Constant.new(
          name: 'Net::HTTP',
          path: 'app/lib/net/http.rb',
          line: 1
        )
        allow(semantic_index).to receive(:resolve_constant)
          .with('Net::HTTP', nesting: [])
          .and_return(shadow_const)

        cs = build_call_site(
          receiver_source: 'Net::HTTP',
          receiver_constant: 'Net::HTTP',
          method_name: :get,
          nesting: []
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'skips when URI is workspace-defined' do
        shadow_const = FiberAudit::Static::SemanticIndex::Constant.new(
          name: 'URI',
          path: 'app/lib/uri.rb',
          line: 1
        )
        allow(semantic_index).to receive(:resolve_constant)
          .with('URI', nesting: [])
          .and_return(shadow_const)

        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"http://example.com"'],
          nesting: []
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with adapter failure' do
      it 'degrades gracefully when resolve_constant raises' do
        allow(semantic_index).to receive(:resolve_constant).and_raise(StandardError.new('adapter error'))

        cs = build_call_site(
          receiver_source: 'Net::HTTP',
          receiver_constant: 'Net::HTTP',
          method_name: :get
        )
        expect { rule.analyze(call_sites: [cs]) }.not_to raise_error
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end

      it 'degrades gracefully when semantic_index is nil' do
        ws_no_sem = double('workspace_no_sem', semantic_index: nil)
        rule_no_sem = described_class.new(
          workspace: ws_no_sem,
          context_resolver: context_resolver,
          configuration: configuration
        )

        cs = build_call_site(
          receiver_source: 'Net::HTTP',
          receiver_constant: 'Net::HTTP',
          method_name: :get
        )
        expect { rule_no_sem.analyze(call_sites: [cs]) }.not_to raise_error
        findings = rule_no_sem.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
      end

      it 'degrades gracefully when workspace has no semantic_index' do
        ws_plain = Object.new
        rule_plain = described_class.new(
          workspace: ws_plain,
          context_resolver: context_resolver,
          configuration: configuration
        )

        cs = build_call_site(
          receiver_source: 'Net::HTTP',
          receiver_constant: 'Net::HTTP',
          method_name: :get
        )
        expect { rule_plain.analyze(call_sites: [cs]) }.not_to raise_error
      end
    end

    context 'with nil receiver_constant' do
      it 'does not match' do
        cs = build_call_site(receiver_constant: nil)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'canonical operations' do
      it 'uses Net::HTTP.method format' do
        cs = build_call_site(method_name: :get_response)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.operation).to eq('Net::HTTP.get_response')
      end

      it 'uses URI.open format' do
        cs = build_call_site(
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"http://example.com"']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.operation).to eq('URI.open')
      end

      it 'uses OpenURI.open_uri format' do
        cs = build_call_site(
          receiver_source: 'OpenURI',
          receiver_constant: 'OpenURI',
          method_name: :open_uri,
          arguments: ['"http://example.com"']
        )
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.operation).to eq('OpenURI.open_uri')
      end
    end

    context 'finding fields' do
      it 'populates all required fields for Net::HTTP' do
        cs = build_call_site(
          path: 'app/controllers/api_controller.rb',
          line: 42,
          column: 4,
          receiver_source: 'Net::HTTP',
          receiver_constant: 'Net::HTTP',
          method_name: :get,
          enclosing_symbol: 'ApiController#fetch_data',
          execution_context: :request,
          confidence: :high
        )
        findings = rule.analyze(call_sites: [cs])
        finding = findings.first

        expect(finding.rule_id).to eq('FA1007')
        expect(finding.title).to eq('Blocking HTTP call in request path')
        expect(finding.category).to eq(:network)
        expect(finding.severity).to eq(:critical)
        expect(finding.confidence).to eq(:high)
        expect(finding.operation).to eq('Net::HTTP.get')
        expect(finding.execution_context).to eq(:request)
        expect(finding.symbol).to eq('ApiController#fetch_data')
        expect(finding.location.path).to eq('app/controllers/api_controller.rb')
        expect(finding.location.line).to eq(42)
        expect(finding.location.column).to eq(4)
        expect(finding.message).to eq(described_class::MESSAGE)
        expect(finding.remediation).to eq(described_class::REMEDIATION)
        expect(finding.evidence.size).to eq(1)
        expect(finding.evidence.first.source).to eq('static_analysis')
        expect(finding.evidence.first.details[:receiver]).to eq('Net::HTTP')
        expect(finding.evidence.first.details[:method]).to eq(:get)
        expect(finding.evidence.first.details[:context]).to eq(:request)
      end

      it 'populates all required fields for URI.open' do
        cs = build_call_site(
          path: 'app/models/external_data.rb',
          line: 15,
          column: 2,
          receiver_source: 'URI',
          receiver_constant: 'URI',
          method_name: :open,
          arguments: ['"http://example.com/data"'],
          enclosing_symbol: 'ExternalData#load',
          execution_context: :middleware,
          confidence: :high
        )
        findings = rule.analyze(call_sites: [cs])
        finding = findings.first

        expect(finding.rule_id).to eq('FA1007')
        expect(finding.severity).to eq(:medium)
        expect(finding.confidence).to eq(:low)
        expect(finding.operation).to eq('URI.open')
        expect(finding.message).to eq(described_class::MESSAGE)
        expect(finding.remediation).to eq(described_class::REMEDIATION)
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

      it 'generates different fingerprints for different operations' do
        cs1 = build_call_site(method_name: :get)
        cs2 = build_call_site(method_name: :get_response)

        findings1 = rule.analyze(call_sites: [cs1])
        findings2 = rule.analyze(call_sites: [cs2])

        expect(findings1.first.fingerprint).not_to eq(findings2.first.fingerprint)
      end
    end

    context 'analyze error handling' do
      it 'returns empty array when unexpected error occurs' do
        cs = double('broken_call_site')
        allow(cs).to receive(:execution_context).and_raise(StandardError.new('unexpected'))

        findings = rule.analyze(call_sites: [cs])
        expect(findings).to eq([])
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
    # Fixture call sites have execution_context: nil, so we set it to :request for testing
    let(:call_sites_with_context) do
      result.call_sites.map do |cs|
        FiberAudit::Static::CallSite.new(**cs.to_h, execution_context: :request)
      end
    end

    context 'positive fixture' do
      let(:fixture_file) { fixtures_path('rules', 'FA1007', 'positive.rb') }

      it 'matches all expected Net::HTTP methods' do
        findings = rule.analyze(call_sites: call_sites_with_context)
        net_http_ops = findings.select { |f| f.operation.start_with?('Net::HTTP.') }.map(&:operation).sort
        expect(net_http_ops).to include('Net::HTTP.get', 'Net::HTTP.get_response', 'Net::HTTP.start')
      end

      it 'matches URI.open and OpenURI.open_uri' do
        findings = rule.analyze(call_sites: call_sites_with_context)
        uri_ops = findings.select { |f| f.operation.start_with?('URI.') || f.operation.start_with?('OpenURI.') }
        expect(uri_ops.map(&:operation)).to include('URI.open')
      end

      it 'all findings have correct rule_id' do
        findings = rule.analyze(call_sites: call_sites_with_context)
        expect(findings.map(&:rule_id).uniq).to eq(['FA1007'])
      end

      it 'all findings have network category' do
        findings = rule.analyze(call_sites: call_sites_with_context)
        expect(findings.map(&:category).uniq).to eq([:network])
      end
    end

    context 'negative fixture' do
      let(:fixture_file) { fixtures_path('rules', 'FA1007', 'negative.rb') }

      it 'does not match any call sites' do
        findings = rule.analyze(call_sites: call_sites_with_context)
        expect(findings).to be_empty
      end
    end
  end
end
