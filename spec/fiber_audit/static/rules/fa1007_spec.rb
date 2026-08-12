# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/rules/net_http_in_request'
require 'fiber_audit/static/call_site'

RSpec.describe FiberAudit::Static::Rules::NetHTTPInRequest do
  let(:workspace) { nil }
  let(:context_resolver) { nil }
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

  def build_call_site(method: :get, context: :request, receiver_constant: 'Net::HTTP', confidence: :high)
    FiberAudit::Static::CallSite.new(
      path: 'app/models/user.rb',
      line: 10,
      column: 4,
      receiver_source: receiver_constant,
      receiver_constant: receiver_constant,
      method_name: method,
      arguments: [],
      enclosing_symbol: 'User#process',
      nesting: ['User'],
      execution_context: context,
      resolution: "#{receiver_constant}.#{method}",
      confidence: confidence
    )
  end

  describe '#analyze' do
    context 'when in request context' do
      it 'detects Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
        expect(findings.first.operation).to eq('Net::HTTP.get')
      end

      it 'detects Net::HTTP.get_response' do
        cs = build_call_site(method: :get_response, context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
        expect(findings.first.operation).to eq('Net::HTTP.get_response')
      end

      it 'detects Net::HTTP.start' do
        cs = build_call_site(method: :start, context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
      end

      it 'detects Net::HTTP.request' do
        cs = build_call_site(method: :request, context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'when in middleware context' do
      it 'detects Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :middleware)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'when in websocket context' do
      it 'detects Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :websocket)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'when in callback context' do
      it 'detects Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :callback)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.size).to eq(1)
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'when in job context' do
      it 'does not detect Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :job)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'when in boot context' do
      it 'does not detect Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :boot)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'when in rake_task context' do
      it 'does not detect Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :rake_task)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'when in test context' do
      it 'does not detect Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :test)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'when in console context' do
      it 'does not detect Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :console)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'when in view context' do
      it 'does not detect Net::HTTP.get' do
        cs = build_call_site(method: :get, context: :view)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'advisory severity (no context escalation)' do
      it 'stays :medium in :request context (no escalation)' do
        cs = build_call_site(method: :get, context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:medium)
      end

      it 'stays :medium in :middleware context (no escalation)' do
        cs = build_call_site(method: :get, context: :middleware)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:medium)
      end

      it 'stays :medium in :callback context' do
        cs = build_call_site(method: :get, context: :callback)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:medium)
      end
    end

    context 'with configuration override' do
      let(:configuration) do
        instance_double(FiberAudit::Configuration, severity_override: :low)
      end

      it 'applies configuration override without context ceiling' do
        cs = build_call_site(method: :get, context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.severity).to eq(:low)
      end
    end

    context 'with wrong method' do
      it 'does not detect Net::HTTP.get_print' do
        cs = build_call_site(method: :get_print, context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect Net::HTTP.post' do
        cs = build_call_site(method: :post, context: :request)
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with wrong receiver_constant' do
      it 'does not detect OtherHTTP.get' do
        cs = build_call_site(method: :get, context: :request, receiver_constant: 'OtherHTTP')
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end

      it 'does not detect HTTP.get' do
        cs = build_call_site(method: :get, context: :request, receiver_constant: 'HTTP')
        findings = rule.analyze(call_sites: [cs])
        expect(findings).to be_empty
      end
    end

    context 'with low confidence' do
      it 'preserves low confidence from call site' do
        cs = build_call_site(method: :get, context: :request, confidence: :low)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:low)
      end
    end

    context 'with high confidence' do
      it 'preserves high confidence from call site' do
        cs = build_call_site(method: :get, context: :request, confidence: :high)
        findings = rule.analyze(call_sites: [cs])
        expect(findings.first.confidence).to eq(:high)
      end
    end
  end

  describe 'metadata' do
    it 'has correct id' do
      expect(described_class.id).to eq('FA1007')
    end

    it 'has correct default severity' do
      expect(described_class.severity).to eq(:medium)
    end

    it 'has correct default confidence' do
      expect(described_class.confidence).to eq(:high)
    end

    it 'has description' do
      expect(described_class.description).to eq(
        'Synchronous HTTP calls may bypass scheduler-aware I/O cooperation in request contexts'
      )
    end
  end

  describe 'finding attributes' do
    it 'includes correct title' do
      cs = build_call_site(method: :get, context: :request)
      finding = rule.analyze(call_sites: [cs]).first
      expect(finding.title).to eq('Blocking HTTP call in request path')
    end

    it 'includes correct category' do
      cs = build_call_site(method: :get, context: :request)
      finding = rule.analyze(call_sites: [cs]).first
      expect(finding.category).to eq(:network)
    end

    it 'includes correct message' do
      cs = build_call_site(method: :get, context: :request)
      finding = rule.analyze(call_sites: [cs]).first
      expect(finding.message).to eq(
        'Synchronous HTTP activity may bypass scheduler-aware I/O cooperation in request-like contexts.'
      )
    end

    it 'includes correct remediation' do
      cs = build_call_site(method: :get, context: :request)
      finding = rule.analyze(call_sites: [cs]).first
      expect(finding.remediation).to eq(
        'Use a scheduler-aware HTTP client, or move outbound HTTP work outside the request path.'
      )
    end

    it 'includes evidence with static source' do
      cs = build_call_site(method: :get, context: :request)
      finding = rule.analyze(call_sites: [cs]).first
      expect(finding.evidence.first.source).to eq('static_analysis')
    end

    it 'includes stable fingerprint' do
      cs1 = build_call_site(method: :get, context: :request)
      cs2 = build_call_site(method: :get, context: :request)
      finding1 = rule.analyze(call_sites: [cs1]).first
      finding2 = rule.analyze(call_sites: [cs2]).first
      expect(finding1.fingerprint).to eq(finding2.fingerprint)
    end
  end
end
