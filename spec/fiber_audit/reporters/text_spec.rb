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

      it 'includes exact header contract' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('FiberAudit 0.1.0 — static analysis')
      end

      it 'includes summary severity, suppressed, and total counts' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Summary')
        expect(output).to include('critical: 0')
        expect(output).to include('high: 1')
        expect(output).to include('medium: 0')
        expect(output).to include('low: 0')
        expect(output).to include('info: 0')
        expect(output).to include('suppressed: 0')
        expect(output).to include('total: 1')
      end

      it 'includes status section' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('status: FAIL')
      end

      it 'includes mandatory disclaimer under status' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include(FiberAudit::Reporters::Schema::DISCLAIMER)

        # Disclaimer should appear after Status
        status_pos = output.index('status:')
        disclaimer_pos = output.index(FiberAudit::Reporters::Schema::DISCLAIMER)
        expect(disclaimer_pos).to be > status_pos
      end

      it 'includes findings with RULE  SEVERITY  path:line format' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Findings')
        expect(output).to include('thread_local_access  HIGH  app/models/user.rb:42')
        expect(output).not_to include('app/models/user.rb:42:10')
      end

      it 'includes symbol — operation [context]' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('User#load_data — Thread.current[:data] [web_request]')
      end

      it 'includes message' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Thread-local variables are not fiber-safe')
      end

      it 'includes footer hint with exact rule explain instruction' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).to include('Run `fiber-audit explain <RULE_ID>` for rule details.')
      end

      it 'does not include ANSI color codes when color: false' do
        reporter = described_class.new(color: false)
        output = reporter.render(result)

        expect(output).not_to include("\e[")
      end
    end

    context 'with color: true' do
      it 'includes ANSI color codes only for severity labels' do
        reporter = described_class.new(color: true)
        output = reporter.render(result)

        expect(output).to include("\e[")
        expect(output).to include(FiberAudit::Reporters::Text::ANSI::YELLOW)
      end

      it 'does not colorize header' do
        reporter = described_class.new(color: true)
        output = reporter.render(result)

        header_line = output.lines.find { |l| l.include?('static analysis') }
        expect(header_line).not_to include("\e[")
      end

      it 'does not colorize footer' do
        reporter = described_class.new(color: true)
        output = reporter.render(result)

        footer_lines = output.lines.select { |l| l.include?('fiber-audit explain') }
        footer_lines.each do |line|
          expect(line).not_to include("\e[")
        end
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

        expect(output).to include('critical: 0')
        expect(output).to include('high: 0')
        expect(output).to include('total: 0')
        expect(output).to include('Run `fiber-audit explain <RULE_ID>` for rule details.')
      end
    end

    context 'with finding without location' do
      it 'renders (unknown location) fallback' do
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

        expect(output).to include('(unknown location)')
      end
    end

    context 'with finding without optional fields' do
      it 'omits absent symbol and operation line' do
        finding_minimal = FiberAudit::Finding.new(
          rule_id: 'test',
          category: 'test',
          severity: :high,
          confidence: :confirmed,
          location: location,
          message: 'test message',
          evidence: evidence
        )

        result_minimal = double('result',
                                findings: [finding_minimal],
                                suppressed: [],
                                parse_errors: [],
                                coverage: coverage,
                                status: 'FAIL')

        reporter = described_class.new(color: false)
        output = reporter.render(result_minimal)

        finding_lines = output.lines.drop_while { |line| !line.start_with?('  test  HIGH') }
        expect(finding_lines[1]).to include('test message')
      end
    end

    context 'with multiple findings' do
      it 'sorts findings by severity and includes the stable footer hint' do
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
        expect(output.scan('Run `fiber-audit explain <RULE_ID>`').size).to eq(1)
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

        expect(output).to include('suppressed: 1')
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
          expect(label).to include(described_class::ANSI::CYAN)
          expect(label).to include('LOW')
        end

        it 'returns colored label for info' do
          label = described_class::ANSI.severity_label(:info, color: true)
          expect(label).to include(described_class::ANSI::CYAN)
          expect(label).to include('INFO')
        end
      end
    end
  end
end
