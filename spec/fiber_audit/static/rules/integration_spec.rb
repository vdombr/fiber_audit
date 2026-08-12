# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/rules/built_ins'

RSpec.describe 'Wave R3 rule integration' do
  rule_cases = {
    'FA1001' => [FiberAudit::Static::Rules::BlockingSubprocess, 20],
    'FA1002' => [FiberAudit::Static::Rules::ThreadJoin, 9],
    'FA1003' => [FiberAudit::Static::Rules::Synchronization, 9],
    'FA1004' => [FiberAudit::Static::Rules::ThreadCurrentState, 4],
    'FA1005' => [FiberAudit::Static::Rules::IOSelect, 4],
    'FA1006' => [FiberAudit::Static::Rules::DirectSocket, 7],
    'FA1007' => [FiberAudit::Static::Rules::NetHTTPInRequest, 10]
  }.freeze

  rule_cases.each do |rule_id, (rule_class, expected_count)|
    it "analyzes the #{rule_id} positive and negative fixtures end to end" do
      root = File.expand_path("../../../fixtures/rules/#{rule_id}", __dir__)
      semantic_index = FiberAudit::Static::SemanticIndex.new(root: root).build
      rule = rule_class.new(
        workspace: semantic_index,
        context_resolver: nil,
        configuration: FiberAudit::Configuration.new
      )

      positive_sites = extract_with_request_context(root, 'positive.rb', semantic_index)
      negative_sites = extract_with_request_context(root, 'negative.rb', semantic_index)
      first_run = rule.analyze(call_sites: positive_sites)
      second_run = rule.analyze(call_sites: positive_sites)

      expect(first_run.size).to eq(expected_count)
      expect(first_run.map(&:rule_id).uniq).to eq([rule_id])
      expect(first_run).to all(satisfy { |finding| finding.message.to_s != '' && finding.remediation.to_s != '' })
      expect(first_run.map(&:fingerprint)).to eq(second_run.map(&:fingerprint))
      expect(rule.analyze(call_sites: negative_sites)).to be_empty
    end
  end

  def extract_with_request_context(root, filename, semantic_index)
    result = FiberAudit::Static::CallSiteExtractor.new(
      files: [File.join(root, filename)],
      semantic_index: semantic_index
    ).call
    raise result.parse_errors.map(&:message).join(', ') unless result.parse_errors.empty?

    result.call_sites.map do |site|
      FiberAudit::Static::CallSite.new(**site.to_h, execution_context: :request)
    end
  end
end
