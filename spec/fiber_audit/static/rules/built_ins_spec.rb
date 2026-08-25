# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/rules/built_ins'

describe FiberAudit::Static::Rules::BuiltIns do
  let(:configuration) { FiberAudit::Configuration.new }

  it 'registers all shipped rules in identifier order' do
    ids = described_class.registry.map(&:id)

    expect(ids).to eq(%w[FA1001 FA1002 FA1003 FA1004 FA1005 FA1006 FA1007 FA1008])
  end

  it 'builds independent registries with injected dependencies' do
    workspace = Object.new
    resolver = Object.new
    first = described_class.registry(workspace: workspace, context_resolver: resolver)
    second = described_class.registry

    expect(first).not_to equal(second)
    expect(first.enabled_for(configuration).map(&:class)).to eq(described_class::RULES)
  end

  it 'respects rule enablement through Registry' do
    configuration = FiberAudit::Configuration.new(
      rules_config: { 'FA1004' => { 'enabled' => false } }
    )

    ids = described_class.registry.enabled_for(configuration).map { |rule| rule.class.id }
    expect(ids).to eq(%w[FA1001 FA1002 FA1003 FA1005 FA1006 FA1007 FA1008])
  end
end
