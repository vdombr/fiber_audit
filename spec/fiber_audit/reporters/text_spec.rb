# frozen_string_literal: true

require 'fiber_audit/reporters/text'
require 'fiber_audit/findings/finding'
require 'fiber_audit/findings/evidence'
require 'fiber_audit/findings/location'

RSpec.describe FiberAudit::Reporters::Text do
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
    context 'with color: false' do
      it 'returns text with exactly one trailing newline' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to end_with("\n")
        expect(output).to match(/\n\z/)
      end

      it 'includes header with version' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('FiberAudit Report')
        expect(output).to include(FiberAudit::VERSION)
        expect(output).to include('schema 1.0')
      end

      it 'includes summary section with severity counts' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Summary:')
        expect(output).to include('CRITICAL: 0')
        expect(output).to include('HIGH: 1')
        expect(output).to include('MEDIUM: 0')
        expect(output).to include('LOW: 0')
        expect(output).to include('INFO: 0')
        expect(output).to include('Suppressed: 0')
        expect(output).to include('Total active: 1')
      end

      it 'includes suppressed findings section' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Suppressed findings: 0')
      end

      it 'includes status section' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Status: FAIL')
      end

      it 'includes mandatory disclaimer' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include(FiberAudit::Reporters::Schema::DISCLAIMER)
      end

      it 'includes findings section' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Findings:')
        expect(output).to include('thread_local_access')
        expect(output).to include('app/models/user.rb:42:10')
        expect(output).to include('User#load_data')
        expect(output).to include('Thread.current[:data]')
        expect(output).to include('web_request')
        expect(output).to include('confirmed')
        expect(output).to include('Thread-local variables are not fiber-safe')
        expect(output).to include('Evidence:')
        expect(output).to include('AST: Thread-local access detected')
      end

      it 'includes footer hint' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Hint:')
        expect(output).to include('Use --format json for machine-readable output')
      end

      it 'does not include ANSI color codes' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).not_to include("\e[")
      end
    end

    context 'with color: true' do
      it 'includes ANSI color codes for severity labels' do
        reporter = described_class.new(color: true)
        output = reporter.render(result)

        expect(output).to include("\e[") # ANSI escape codes present
        expect(output).to include(FiberAudit::Reporters::Text::ANSI::YELLOW)
      end

      it 'includes footer hint with color' do
        reporter = described_class.new(color: true)
        output = reporter.render(result)

        expect(output).to include(FiberAudit::Reporters::Text::ANSI::CYAN)
      end
    end

    context 'with no findings' do
      it 'renders explicit no-findings message' do
        empty_result = double('result',
                              findings: [],
                              suppressed: [],
                              parse_errors: [],
                              coverage: coverage,
                              status: 'NO_FINDINGS')

        reporter = described_class.new(color: false)
        output = reporter.render(empty_result)

        expect(output).to include('No findings.')
      end

      it 'shows zero counts in summary' do
        empty_result = double('result',
                              findings: [],
                              suppressed: [],
                              parse_errors: [],
                              coverage: coverage,
                              status: 'NO_FINDINGS')

        reporter = described_class.new(color: false)
        output = reporter.render(empty_result)

        expect(output).to include('CRITICAL: 0')
        expect(output).to include('HIGH: 0')
        expect(output).to include('Total active: 0')
      end
    end

    context 'with finding without optional fields' do
      it 'omits absent symbol' do
        finding_no_symbol = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          location: location,
          message: 'test message',
          evidence: evidence
        )

        result_no_symbol = double('result',
                                  findings: [finding_no_symbol],
                                  suppressed: [],
                                  parse_errors: [],
                                  coverage: coverage,
                                  status: 'FAIL')

        reporter = described_class.new(color: false)
        output = reporter.render(result_no_symbol)

        expect(output).not_to include('Symbol:')
      end

      it 'omits absent operation' do
        finding_no_op = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          location: location,
          symbol: 'TestClass#method',
          message: 'test message',
          evidence: evidence
        )

        result_no_op = double('result',
                              findings: [finding_no_op],
                              suppressed: [],
                              parse_errors: [],
                              coverage: coverage,
                              status: 'FAIL')

        reporter = described_class.new(color: false)
        output = reporter.render(result_no_op)

        expect(output).not_to include('Operation:')
      end

      it 'omits absent execution_context' do
        finding_no_ctx = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          location: location,
          symbol: 'TestClass#method',
          message: 'test message',
          evidence: evidence
        )

        result_no_ctx = double('result',
                               findings: [finding_no_ctx],
                               suppressed: [],
                               parse_errors: [],
                               coverage: coverage,
                               status: 'FAIL')

        reporter = described_class.new(color: false)
        output = reporter.render(result_no_ctx)

        expect(output).not_to include('Context:')
      end
    end

    context 'with finding without location' do
      it 'renders stable unknown location' do
        finding_no_loc = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          message: 'test message',
          evidence: evidence
        )

        result_no_loc = double('result',
                               findings: [finding_no_loc],
                               suppressed: [],
                               parse_errors: [],
                               coverage: coverage,
                               status: 'FAIL')

        reporter = described_class.new(color: false)
        output = reporter.render(result_no_loc)

        expect(output).to include('Location: <unknown>')
      end
    end

    context 'with multiple findings' do
      it 'sorts findings by severity' do
        loc = FiberAudit::Location.new(path: 'test.rb', line: 1, column: 1)

        finding_critical = FiberAudit::Finding.new(
          rule_id: 'rule_c',
          category: 'test',
          severity: :critical,
          confidence: :confirmed,
          location: loc,
          message: 'critical',
          evidence: evidence
        )

        finding_low = FiberAudit::Finding.new(
          rule_id: 'rule_l',
          category: 'test',
          severity: :low,
          confidence: :confirmed,
          location: loc,
          message: 'low',
          evidence: evidence
        )

        finding_high = FiberAudit::Finding.new(
          rule_id: 'rule_h',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          location: loc,
          message: 'high',
          evidence: evidence
        )

        result_multi = double('result',
                              findings: [finding_low, finding_critical, finding_high],
                              suppressed: [],
                              parse_errors: [],
                              coverage: coverage,
                              status: 'FAIL')

        reporter = described_class.new(color: false)
        output = reporter.render(result_multi)

        # Critical should appear before high, which should appear before low
        critical_pos = output.index('rule_c')
        high_pos = output.index('rule_h')
        low_pos = output.index('rule_l')

        expect(critical_pos).to be < high_pos
        expect(high_pos).to be < low_pos
      end
    end

    context 'with suppressed findings' do
      it 'shows suppressed count in summary' do
        suppressed_finding = FiberAudit::Finding.new(
          rule_id: 'suppressed',
          category: 'test',
          severity: :low,
          confidence: :confirmed,
          location: location,
          message: 'suppressed',
          evidence: evidence
        )

        result_suppressed = double('result',
                                   findings: [finding],
                                   suppressed: [suppressed_finding],
                                   parse_errors: [],
                                   coverage: coverage,
                                   status: 'FAIL')

        reporter = described_class.new(color: false)
        output = reporter.render(result_suppressed)

        expect(output).to include('Suppressed: 1')
        expect(output).to include('Suppressed findings: 1')
      end
    end

    context 'schema validation' do
      it 'raises ReporterError for invalid result' do
        bad_result = double('result', findings: [], suppressed: [], parse_errors: [], coverage: coverage, status: 'PASS')

        reporter = described_class.new(color: false)
        expect { reporter.render(bad_result) }.to raise_error(FiberAudit::ReporterError)
      end
    end
  end

  describe 'Text::ANSI' do
    describe '.severity_label' do
      context 'with color: false' do
        it 'returns plain uppercase label' do
          label = described_class::ANSI.severity_label(:high, color: false)
          expect(label).to eq('HIGH')
        end
      end

      context 'with color: true' do
        it 'returns colored label for critical' do
          label = described_class::ANSI.severity_label(:critical, color: true)
          expect(label).to include(described_class::ANSI::RED)
          expect(label).to include('CRITICAL')
          expect(label).to include(described_class::ANSI::RESET)
        end

        it 'returns colored label for high' do
          label = described_class::ANSI.severity_label(:high, color: true)
          expect(label).to include(described_class::ANSI::YELLOW)
          expect(label).to include('HIGH')
        end

        it 'returns colored label for low' do
          label = described_class::ANSI.severity_label(:low, color: true)
          expect(label).to include(described_class::ANSI::GREEN)
          expect(label).to include('LOW')
        end

        it 'returns colored label for info' do
          label = described_class::ANSI.severity_label(:info, color: true)
          expect(label).to include(described_class::ANSI::BLUE)
          expect(label).to include('INFO')
        end
      end
    end
  end
end
