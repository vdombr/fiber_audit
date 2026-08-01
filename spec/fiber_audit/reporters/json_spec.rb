# frozen_string_literal: true

require 'fiber_audit/reporters/json'
require 'fiber_audit/findings/finding'
require 'fiber_audit/findings/evidence'
require 'fiber_audit/findings/location'
require 'json'

RSpec.describe FiberAudit::Reporters::JSON do
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

  let(:coverage) do
    double('coverage',
           analysed_files: 10,
           total_call_sites: 100,
           rules_run: 5)
  end

  let(:result) do
    double('result',
           findings: [finding],
           suppressed: [],
           parse_errors: [],
           coverage: coverage,
           status: 'FAIL')
  end

  describe '#render' do
    context 'with pretty: false' do
      it 'returns compact JSON with exactly one trailing newline' do
        reporter = described_class.new(pretty: false)
        output = reporter.render(result)

        expect(output).to end_with("\n")
        expect(output.count("\n")).to eq(1)
      end

      it 'produces valid JSON' do
        reporter = described_class.new(pretty: false)
        output = reporter.render(result)

        expect { ::JSON.parse(output) }.not_to raise_error
      end

      it 'normalizes symbol keys to strings' do
        reporter = described_class.new(pretty: false)
        output = reporter.render(result)
        parsed = ::JSON.parse(output)

        expect(parsed.keys).to all(be_a(String))
      end

      it 'normalizes symbol values to strings' do
        reporter = described_class.new(pretty: false)
        output = reporter.render(result)
        parsed = ::JSON.parse(output)

        expect(parsed['findings'][0]['severity']).to eq('high')
        expect(parsed['findings'][0]['confidence']).to eq('confirmed')
      end

      it 'maintains deterministic top-level key order' do
        reporter = described_class.new(pretty: false)
        output = reporter.render(result)
        parsed = ::JSON.parse(output)

        expected_keys = %w[
          schema_version tool_version status disclaimer summary
          coverage findings suppressed parse_errors
        ]
        expect(parsed.keys).to eq(expected_keys)
      end
    end

    context 'with pretty: true' do
      it 'returns formatted JSON with exactly one trailing newline' do
        reporter = described_class.new(pretty: true)
        output = reporter.render(result)

        expect(output).to end_with("\n")
        expect(output.count("\n")).to be > 1 # Pretty printed has multiple lines
        expect(output).to match(/\n\z/) # Ends with newline
      end

      it 'produces valid JSON' do
        reporter = described_class.new(pretty: true)
        output = reporter.render(result)

        expect { ::JSON.parse(output) }.not_to raise_error
      end

      it 'includes formatting whitespace' do
        reporter = described_class.new(pretty: true)
        output = reporter.render(result)

        expect(output).to include("  ") # Indentation
        expect(output).to include("\n") # Newlines
      end
    end

    context 'with no findings' do
      it 'renders empty findings array' do
        empty_result = double('result',
                              findings: [],
                              suppressed: [],
                              parse_errors: [],
                              coverage: coverage,
                              status: 'NO_FINDINGS')

        reporter = described_class.new(pretty: false)
        output = reporter.render(empty_result)
        parsed = ::JSON.parse(output)

        expect(parsed['findings']).to eq([])
        expect(parsed['status']).to eq('NO_FINDINGS')
      end
    end

    context 'with suppressed findings' do
      it 'renders suppressed array separately' do
        suppressed_finding = FiberAudit::Finding.new(
          rule_id: 'suppressed_rule',
          category: 'test',
          severity: :low,
          confidence: :confirmed,
          location: location,
          message: 'suppressed',
          evidence: evidence
        )

        result_with_suppressed = double('result',
                                        findings: [finding],
                                        suppressed: [suppressed_finding],
                                        parse_errors: [],
                                        coverage: coverage,
                                        status: 'FAIL')

        reporter = described_class.new(pretty: false)
        output = reporter.render(result_with_suppressed)
        parsed = ::JSON.parse(output)

        expect(parsed['findings'].size).to eq(1)
        expect(parsed['suppressed'].size).to eq(1)
        expect(parsed['summary']['suppressed']).to eq(1)
      end
    end

    context 'with parse errors' do
      it 'renders parse errors with path, message, and nullable line' do
        parse_error = double('parse_error', path: 'broken.rb', message: 'syntax error', line: 42)
        parse_error_nil = double('parse_error', path: 'broken2.rb', message: 'another error', line: nil)

        result_with_errors = double('result',
                                    findings: [],
                                    suppressed: [],
                                    parse_errors: [parse_error, parse_error_nil],
                                    coverage: coverage,
                                    status: 'REVIEW')

        reporter = described_class.new(pretty: false)
        output = reporter.render(result_with_errors)
        parsed = ::JSON.parse(output)

        expect(parsed['parse_errors']).to eq([
                                               { 'path' => 'broken.rb', 'message' => 'syntax error', 'line' => 42 },
                                               { 'path' => 'broken2.rb', 'message' => 'another error', 'line' => nil }
                                             ])
      end
    end

    context 'schema validation' do
      it 'raises ReporterError for invalid result' do
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: coverage, status: 'PASS')

        reporter = described_class.new(pretty: false)
        expect { reporter.render(bad_result) }.to raise_error(FiberAudit::ReporterError)
      end
    end

    it 'uses ::JSON to avoid class collision' do
      # This test ensures we're using the top-level ::JSON module
      reporter = described_class.new(pretty: false)
      output = reporter.render(result)

      # If we were using FiberAudit::Reporters::JSON by mistake, this would fail
      expect { ::JSON.parse(output) }.not_to raise_error
    end
  end
end
