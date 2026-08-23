# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/audit'
require 'fiber_audit/reporters/json'
require 'pathname'

RSpec.describe 'rails blockers golden report' do
  it 'matches the intentional FA1004/FA1006 contract update with stable identities' do
    root = File.expand_path('../../fixtures/apps/rails_blockers', __dir__)
    golden_path = File.expand_path('../../fixtures/reports/rails_blockers_v0.3.0.json', __dir__)
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
    expect(parsed.fetch('status')).to eq('REVIEW')
    expect(parsed.fetch('summary')).to include('critical' => 0, 'medium' => 4, 'total' => 7)
    expect(findings.map { |finding| finding.fetch('rule_id') }).to eq(
      %w[FA1001 FA1004 FA1005 FA1007 FA1002 FA1003 FA1006]
    )

    fa1004 = findings.find { |finding| finding.fetch('rule_id') == 'FA1004' }
    fa1006 = findings.find { |finding| finding.fetch('rule_id') == 'FA1006' }
    expect(fa1004).to include(
      'severity' => 'medium',
      'operation' => 'Thread.thread_variable_get',
      'fingerprint' => 'ae61d31894596bb0908c5bc7ac7a498f589bd9d784225790ec75579b55e05066'
    )
    expect(fa1006).to include(
      'operation' => 'TCPSocket.new',
      'fingerprint' => '1722124be59a67a7e385b0f8c53bdc391790e094eedfa6c43e3bdbaf7c4c4bd5'
    )
    expect(fa1006.dig('evidence', 0, 'details')).to include(
      'semantic' => 'socket_resolve_connect',
      'scheduler_capability' => 'address_resolve'
    )
  end
end
