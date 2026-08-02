# frozen_string_literal: true

require 'fiber_audit/reporters/schema'
require 'fiber_audit/findings/finding'
require 'fiber_audit/findings/evidence'
require 'fiber_audit/findings/location'

RSpec.describe FiberAudit::Reporters::Schema do
  let(:location) { FiberAudit::Location.new(path: 'app/models/user.rb', line: 42, column: 10) }
  let(:evidence) { [FiberAudit::Evidence.new(source: 'AST', message: 'Thread-local access detected')] }

  let(:finding) do
    FiberAudit::Finding.new(
      rule_id: 'thread_local_access',
      title: 'Thread-local variable access',
      category: 'concurrency',
      severity: :high,
      confidence: :confirmed,
      location: location,
      symbol: 'User#load_data',
      operation: 'Thread.current[:data]',
      execution_context: 'web_request',
      message: 'Thread-local variables are not fiber-safe',
      evidence: evidence,
      remediation: 'Use Fiber.current instead'
    )
  end

  let(:findings) { [finding] }
  let(:suppressed) { [] }
  let(:parse_errors) { [] }

  let(:coverage) do
    double('coverage',
           analysed_files: 10,
           total_call_sites: 100,
           rules_run: 5)
  end

  let(:result) do
    double('result',
           findings: findings,
           suppressed: suppressed,
           parse_errors: parse_errors,
           coverage: coverage,
           status: 'FAIL')
  end

  describe '.build' do
    context 'with valid result' do
      it 'returns a hash with correct structure' do
        hash = described_class.build(result)
        expect(hash).to be_a(Hash)
      end

      it 'includes schema_version' do
        hash = described_class.build(result)
        expect(hash[:schema_version]).to eq('1.0')
      end

      it 'includes tool_version' do
        hash = described_class.build(result)
        expect(hash[:tool_version]).to eq(FiberAudit::VERSION)
      end

      it 'includes status' do
        hash = described_class.build(result)
        expect(hash[:status]).to eq('FAIL')
      end

      it 'includes mandatory disclaimer' do
        hash = described_class.build(result)
        expect(hash[:disclaimer]).to eq(described_class::DISCLAIMER)
      end

      it 'includes summary with correct counts using total key' do
        hash = described_class.build(result)
        expect(hash[:summary]).to include(
          critical: 0,
          high: 1,
          medium: 0,
          low: 0,
          info: 0,
          suppressed: 0,
          total: 1
        )
      end

      it 'includes coverage' do
        hash = described_class.build(result)
        expect(hash[:coverage]).to include(
          analysed_files: 10,
          total_call_sites: 100,
          rules_run: 5
        )
      end

      it 'includes findings array as hashes' do
        hash = described_class.build(result)
        expect(hash[:findings]).to be_an(Array)
        expect(hash[:findings].size).to eq(1)
        expect(hash[:findings][0]).to be_a(Hash)
      end

      it 'normalizes finding to hash with string severity/confidence' do
        hash = described_class.build(result)
        finding_hash = hash[:findings][0]
        expect(finding_hash[:severity]).to eq('high')
        expect(finding_hash[:confidence]).to eq('confirmed')
      end

      it 'includes suppressed array' do
        hash = described_class.build(result)
        expect(hash[:suppressed]).to be_an(Array)
        expect(hash[:suppressed]).to be_empty
      end

      it 'includes parse_errors array' do
        hash = described_class.build(result)
        expect(hash[:parse_errors]).to be_an(Array)
        expect(hash[:parse_errors]).to be_empty
      end

      it 'returns deterministic top-level key order' do
        hash = described_class.build(result)
        expected_keys = %i[
          schema_version tool_version status disclaimer summary
          coverage findings suppressed parse_errors
        ]
        expect(hash.keys).to eq(expected_keys)
      end
    end

    context 'with missing interface methods' do
      it 'raises ReporterError when result missing findings' do
        bad_result = double('result', suppressed: [], parse_errors: [], coverage: coverage, status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /must respond to findings/
        )
      end

      it 'raises ReporterError when result missing status' do
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: coverage)
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /must respond to status/
        )
      end
    end

    context 'with invalid status' do
      it 'raises ReporterError for PASS status' do
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: coverage, status: 'PASS')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /invalid status.*PASS/
        )
      end

      it 'raises ReporterError for unknown status' do
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: coverage, status: 'UNKNOWN')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /invalid status.*UNKNOWN/
        )
      end

      it 'accepts all allowed statuses' do
        %w[FAIL REVIEW PASS_WITH_WARNINGS NO_FINDINGS].each do |status|
          good_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: coverage, status: status)
          expect { described_class.build(good_result) }.not_to raise_error
        end
      end
    end

    context 'with empty evidence' do
      it 'raises ReporterError for finding with no evidence' do
        finding_no_evidence = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          message: 'test',
          evidence: []
        )
        bad_result = double('result', findings: [finding_no_evidence], suppressed: [], parse_errors: [], coverage: coverage,
                                      status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /must have non-empty evidence/
        )
      end
    end

    context 'with invalid location' do
      it 'raises ReporterError for location with non-positive line' do
        bad_location = FiberAudit::Location.new(path: 'test.rb', line: 0, column: 1)
        finding_bad_loc = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          location: bad_location,
          message: 'test',
          evidence: evidence
        )
        bad_result = double('result', findings: [finding_bad_loc], suppressed: [], parse_errors: [], coverage: coverage,
                                      status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /location line must be positive/
        )
      end

      it 'raises ReporterError for location with negative column' do
        bad_location = FiberAudit::Location.new(path: 'test.rb', line: 1, column: -1)
        finding_bad_loc = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          location: bad_location,
          message: 'test',
          evidence: evidence
        )
        bad_result = double('result', findings: [finding_bad_loc], suppressed: [], parse_errors: [], coverage: coverage,
                                      status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /location column must be non-negative/
        )
      end
    end

    context 'with symbol-valued built-in rule data' do
      it 'normalizes optional fields and nested evidence details to primitives' do
        symbol_evidence = FiberAudit::Evidence.new(
          source: :static,
          message: 'matched',
          details: { receiver: :Kernel, nested: [:system, { context: :request }] }
        )
        symbol_finding = FiberAudit::Finding.new(
          rule_id: 'FA1001',
          title: 'Blocking subprocess call',
          category: :subprocess,
          severity: :high,
          confidence: :high,
          execution_context: :request,
          message: 'matched',
          evidence: [symbol_evidence]
        )
        symbol_result = double(
          'result', findings: [symbol_finding], suppressed: [], parse_errors: [],
                    coverage: coverage, status: 'FAIL'
        )

        normalized = described_class.build(symbol_result).fetch(:findings).first

        expect(normalized[:category]).to eq('subprocess')
        expect(normalized[:execution_context]).to eq('request')
        expect(normalized.dig(:evidence, 0, :source)).to eq('static')
        expect(normalized.dig(:evidence, 0, :details)).to eq(
          'receiver' => 'Kernel',
          'nested' => ['system', { 'context' => 'request' }]
        )
      end
    end

    context 'with non-JSON-safe details' do
      it 'raises ReporterError for evidence with non-JSON-safe details' do
        bad_evidence = FiberAudit::Evidence.new(
          source: 'test',
          message: 'test',
          details: { bad: Object.new }
        )
        finding_bad_ev = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          message: 'test',
          evidence: [bad_evidence]
        )
        bad_result = double('result', findings: [finding_bad_ev], suppressed: [], parse_errors: [], coverage: coverage,
                                      status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /not JSON-safe/
        )
      end
    end

    context 'with invalid parse errors' do
      it 'raises ReporterError for parse error missing path' do
        bad_parse_error = double('parse_error', message: 'syntax error')
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [bad_parse_error], coverage: coverage,
                                      status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /must respond to :path and :message/
        )
      end

      it 'raises ReporterError for parse error with non-positive line' do
        bad_parse_error = double('parse_error', path: 'test.rb', message: 'syntax error', line: 0)
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [bad_parse_error], coverage: coverage,
                                      status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /line must be positive/
        )
      end

      it 'accepts parse error with nil line' do
        parse_error = double('parse_error', path: 'test.rb', message: 'syntax error', line: nil)
        good_result = double('result', findings: [], suppressed: [], parse_errors: [parse_error], coverage: coverage,
                                       status: 'FAIL')
        expect { described_class.build(good_result) }.not_to raise_error
      end
    end

    context 'with invalid coverage' do
      it 'raises ReporterError for negative analysed_files' do
        bad_coverage = double('coverage', analysed_files: -1, total_call_sites: 100, rules_run: 5)
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: bad_coverage, status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /coverage\.analysed_files must be a non-negative Integer/
        )
      end

      it 'raises ReporterError for non-Integer total_call_sites' do
        bad_coverage = double('coverage', analysed_files: 10, total_call_sites: '100', rules_run: 5)
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: bad_coverage, status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /coverage\.total_call_sites must be a non-negative Integer/
        )
      end

      it 'raises ReporterError for coverage missing methods' do
        bad_coverage = double('coverage', analysed_files: 10, total_call_sites: 100)
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: bad_coverage, status: 'FAIL')
        expect { described_class.build(bad_result) }.to raise_error(
          FiberAudit::ReporterError,
          /coverage must respond to :analysed_files, :total_call_sites, :rules_run/
        )
      end
    end

    context 'with multiple findings' do
      it 'sorts findings by severity, rule_id, path, line, fingerprint' do
        loc1 = FiberAudit::Location.new(path: 'a.rb', line: 10, column: 1)
        loc2 = FiberAudit::Location.new(path: 'b.rb', line: 5, column: 1)

        finding1 = FiberAudit::Finding.new(
          rule_id: 'rule_b',
          category: 'test',
          severity: :low,
          confidence: :confirmed,
          location: loc1,
          message: 'test',
          evidence: evidence
        )

        finding2 = FiberAudit::Finding.new(
          rule_id: 'rule_a',
          category: 'test',
          severity: :critical,
          confidence: :confirmed,
          location: loc2,
          message: 'test',
          evidence: evidence
        )

        finding3 = FiberAudit::Finding.new(
          rule_id: 'rule_a',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          location: loc1,
          message: 'test',
          evidence: evidence
        )

        result_with_findings = double('result',
                                      findings: [finding1, finding2, finding3],
                                      suppressed: [],
                                      parse_errors: [],
                                      coverage: coverage,
                                      status: 'FAIL')

        hash = described_class.build(result_with_findings)
        sorted = hash[:findings]

        # Critical should come first
        expect(sorted[0][:severity]).to eq('critical')
        expect(sorted[0][:rule_id]).to eq('rule_a')

        # High should come second
        expect(sorted[1][:severity]).to eq('high')

        # Low should come last
        expect(sorted[2][:severity]).to eq('low')
      end

      it 'builds correct summary counts with total key' do
        findings_multi = [
          FiberAudit::Finding.new(rule_id: 'r1', category: 'c', severity: :critical, confidence: :confirmed, message: 'm',
                                  evidence: evidence),
          FiberAudit::Finding.new(rule_id: 'r2', category: 'c', severity: :critical, confidence: :confirmed, message: 'm',
                                  evidence: evidence),
          FiberAudit::Finding.new(rule_id: 'r3', category: 'c', severity: :high, confidence: :confirmed, message: 'm',
                                  evidence: evidence),
          FiberAudit::Finding.new(rule_id: 'r4', category: 'c', severity: :medium, confidence: :confirmed, message: 'm',
                                  evidence: evidence),
          FiberAudit::Finding.new(rule_id: 'r5', category: 'c', severity: :low, confidence: :confirmed, message: 'm',
                                  evidence: evidence),
          FiberAudit::Finding.new(rule_id: 'r6', category: 'c', severity: :info, confidence: :confirmed, message: 'm',
                                  evidence: evidence)
        ]

        suppressed_multi = [
          FiberAudit::Finding.new(rule_id: 'r7', category: 'c', severity: :high, confidence: :confirmed, message: 'm',
                                  evidence: evidence)
        ]

        result_multi = double('result',
                              findings: findings_multi,
                              suppressed: suppressed_multi,
                              parse_errors: [],
                              coverage: coverage,
                              status: 'FAIL')

        hash = described_class.build(result_multi)
        expect(hash[:summary]).to include(
          critical: 2,
          high: 1,
          medium: 1,
          low: 1,
          info: 1,
          suppressed: 1,
          total: 6
        )
      end
    end

    context 'with Collection instead of Array' do
      it 'accepts Collection for findings' do
        collection = FiberAudit::Collection.new([finding])
        result_with_collection = double('result',
                                        findings: collection,
                                        suppressed: [],
                                        parse_errors: [],
                                        coverage: coverage,
                                        status: 'FAIL')

        hash = described_class.build(result_with_collection)
        expect(hash[:findings]).to be_an(Array)
        expect(hash[:findings].size).to eq(1)
      end
    end

    context 'with parse errors' do
      it 'preserves path, message, and nullable line' do
        parse_error = double('parse_error', path: 'broken.rb', message: 'syntax error', line: 42)
        parse_error_nil_line = double('parse_error', path: 'broken2.rb', message: 'another error', line: nil)

        result_with_errors = double('result',
                                    findings: [],
                                    suppressed: [],
                                    parse_errors: [parse_error, parse_error_nil_line],
                                    coverage: coverage,
                                    status: 'REVIEW')

        hash = described_class.build(result_with_errors)
        expect(hash[:parse_errors]).to eq([
                                            { path: 'broken.rb', message: 'syntax error', line: 42 },
                                            { path: 'broken2.rb', message: 'another error', line: nil }
                                          ])
      end
    end
  end

  describe '.validate!' do
    let(:built_hash) { described_class.build(result) }

    context 'with valid report hash' do
      it 'returns the hash frozen' do
        validated = described_class.validate!(built_hash)
        expect(validated).to be_frozen
        expect(validated).to eq(built_hash)
      end
    end

    context 'with invalid severity string in hash' do
      it 'raises ReporterError using primitive hash construction' do
        bad_hash = built_hash.dup
        bad_hash[:findings] = [built_hash[:findings][0].dup]
        bad_hash[:findings][0][:severity] = 'unknown_severity'

        expect { described_class.validate!(bad_hash) }.to raise_error(
          FiberAudit::ReporterError,
          /severity must be known severity string/
        )
      end
    end

    context 'with invalid confidence string in hash' do
      it 'raises ReporterError using primitive hash construction' do
        bad_hash = built_hash.dup
        bad_hash[:findings] = [built_hash[:findings][0].dup]
        bad_hash[:findings][0][:confidence] = 'unknown_confidence'

        expect { described_class.validate!(bad_hash) }.to raise_error(
          FiberAudit::ReporterError,
          /confidence must be known confidence string/
        )
      end
    end

    context 'with missing required keys' do
      it 'raises ReporterError for missing top-level key' do
        incomplete_hash = built_hash.dup
        incomplete_hash.delete(:schema_version)

        expect { described_class.validate!(incomplete_hash) }.to raise_error(
          FiberAudit::ReporterError,
          /missing required keys.*schema_version/
        )
      end

      it 'raises ReporterError for unknown top-level key' do
        bad_hash = built_hash.dup
        bad_hash[:unknown_key] = 'bad'

        expect { described_class.validate!(bad_hash) }.to raise_error(
          FiberAudit::ReporterError,
          /has unknown keys.*unknown_key/
        )
      end

      it 'raises ReporterError for missing summary key' do
        bad_hash = built_hash.dup
        bad_hash[:summary] = built_hash[:summary].dup
        bad_hash[:summary].delete(:total)

        expect { described_class.validate!(bad_hash) }.to raise_error(
          FiberAudit::ReporterError,
          /summary missing required keys.*total/
        )
      end
    end

    context 'with summary count inconsistencies' do
      it 'raises ReporterError when summary does not match findings' do
        bad_hash = built_hash.dup
        bad_hash[:summary] = built_hash[:summary].dup
        bad_hash[:summary][:high] = 999 # Wrong count

        expect { described_class.validate!(bad_hash) }.to raise_error(
          FiberAudit::ReporterError,
          /summary.*does not match/
        )
      end
    end
  end
end
