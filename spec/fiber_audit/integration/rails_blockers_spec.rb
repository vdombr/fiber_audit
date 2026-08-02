# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/audit'
require 'fiber_audit/reporters/json'
require 'pathname'

RSpec.describe 'rails blockers golden report' do
  it 'matches the versioned report with portable paths and fingerprints' do
    root = File.expand_path('../../fixtures/apps/rails_blockers', __dir__)
    golden_path = File.expand_path('../../fixtures/reports/rails_blockers_v0.1.json', __dir__)
    configuration = FiberAudit::Configuration.new

    absolute_result = FiberAudit::Audit.new(configuration: configuration, root: root).call
    absolute_report = FiberAudit::Reporters::JSON.new(pretty: true).render(absolute_result)

    relative_root = Pathname.new(root).relative_path_from(Pathname.pwd).to_s
    relative_result = FiberAudit::Audit.new(configuration: configuration, root: relative_root).call
    relative_report = FiberAudit::Reporters::JSON.new(pretty: true).render(relative_result)

    parsed = JSON.parse(absolute_report)
    findings = parsed.fetch('findings')

    expect(absolute_report).to eq(File.binread(golden_path))
    expect(relative_report).to eq(absolute_report)
    expect(absolute_report).not_to include(root)
    expect(findings.map { |finding| finding.fetch('rule_id') }).to eq(
      %w[FA1001 FA1002 FA1003 FA1004 FA1005 FA1006 FA1007]
    )
    expect(findings.map { |finding| finding.fetch('fingerprint') })
      .to eq(relative_result.findings.map(&:fingerprint))
  end
end
