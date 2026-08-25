# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/rules/blocking_fiber_context'
require 'fiber_audit/static/call_site'

RSpec.describe FiberAudit::Static::Rules::BlockingFiberContext do
  let(:configuration) { FiberAudit::Configuration.new }
  let(:rule) { described_class.new(workspace: Object.new, context_resolver: nil, configuration: configuration) }

  def context(kind, line)
    FiberAudit::Static::FiberContext.new(kind: kind, line: line, column: 2)
  end

  def site(ctx:, line:, receiver_source: 'Fiber', receiver_constant: 'Fiber', method_name: :new, resolution: nil)
    FiberAudit::Static::CallSite.new(
      path: 'app/worker.rb', line: line, column: 2, receiver_source: receiver_source,
      receiver_constant: receiver_constant, method_name: method_name, arguments: [],
      enclosing_symbol: 'Worker#call', nesting: [], execution_context: :job,
      resolution: resolution || "#{receiver_constant}.#{method_name}", confidence: :high,
      fiber_context: ctx
    )
  end

  it 'reports explicit regions and nested waits' do
    ctx = context(:fiber_new, 1)
    nested_select = site(
      ctx: ctx, line: 2, receiver_source: 'IO', receiver_constant: 'IO',
      method_name: :select, resolution: 'IO.select'
    )
    finding = rule.analyze(call_sites: [site(ctx: ctx, line: 1), nested_select]).first
    expect(finding).to have_attributes(rule_id: 'FA1008', severity: :medium, operation: 'Fiber.new(blocking: true)')
    expect(finding.evidence.map(&:message)).to include(/IO\.select/)
  end

  it 'keeps wait-free regions low and ignores unrelated contexts' do
    ctx = context(:fiber_blocking, 1)
    expect(rule.analyze(call_sites: [site(ctx: ctx, line: 1, method_name: :blocking)]).first.severity).to eq(:low)
    other = site(ctx: nil, line: 2, receiver_source: 'IO', receiver_constant: 'IO', method_name: :select,
                 resolution: 'IO.select')
    expect(rule.analyze(call_sites: [other])).to be_empty
  end

  it 'preserves fingerprints when line changes' do
    first = context(:fiber_new, 1)
    second = context(:fiber_new, 20)
    expect(rule.analyze(call_sites: [site(ctx: first, line: 1)]).first.fingerprint)
      .to eq(rule.analyze(call_sites: [site(ctx: second, line: 20)]).first.fingerprint)
  end
end
