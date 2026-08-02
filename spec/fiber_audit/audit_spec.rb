# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/audit'
require 'tmpdir'
require 'fileutils'

RSpec.describe FiberAudit::Audit do
  around do |example|
    Dir.mktmpdir do |directory|
      @root = File.realpath(directory)
      FileUtils.mkdir_p(File.join(@root, 'app'))
      File.write(File.join(@root, 'app', 'sample.rb'), "puts 'sample'\n")
      example.run
    end
  end

  let(:root) { @root }
  let(:configuration) do
    FiberAudit::Configuration.new(
      static_include: ['app/**/*.rb'],
      static_exclude: []
    )
  end
  let(:semantic_index) { instance_double(FiberAudit::Static::SemanticIndex) }
  let(:extractor) { instance_double(FiberAudit::Static::CallSiteExtractor) }
  let(:context_resolver) { instance_double(FiberAudit::Static::ExecutionContextResolver) }
  let(:registry) { instance_double(FiberAudit::Static::Rules::Registry) }
  let(:rule) { instance_double(FiberAudit::Static::Rules::Base) }
  let(:call_sites) { [] }
  let(:parse_errors) { [] }
  let(:rule_findings) { [] }
  let(:extraction) do
    FiberAudit::Static::CallSiteExtractor::Result.new(
      call_sites: call_sites,
      parse_errors: parse_errors
    )
  end

  before do
    allow(FiberAudit::Static::SemanticIndex).to receive(:new).and_return(semantic_index)
    allow(semantic_index).to receive(:build).and_return(semantic_index)
    allow(FiberAudit::Static::CallSiteExtractor).to receive(:new).and_return(extractor)
    allow(extractor).to receive(:call).and_return(extraction)
    allow(FiberAudit::Static::ExecutionContextResolver).to receive(:new).and_return(context_resolver)
    allow(context_resolver).to receive(:resolve_all) { |call_sites:| call_sites }
    allow(FiberAudit::Static::Rules::BuiltIns).to receive(:registry).and_return(registry)
    allow(registry).to receive(:enabled_for).and_return([rule])
    allow(rule).to receive(:analyze).and_return(rule_findings)
  end

  describe 'contracts' do
    it 'defines the exact Result and Coverage values' do
      expect(described_class::Result.members).to eq(%i[findings suppressed parse_errors coverage status])
      expect(described_class::Coverage.members).to eq(%i[analysed_files total_call_sites rules_run])
    end

    it 'normalizes the root to a canonical absolute path' do
      dirty_root = File.join(root, 'app', '..')
      audit = described_class.new(configuration: configuration, root: dirty_root)

      expect(audit.root).to eq(Pathname.new(root))
      expect(audit.root).to be_absolute
    end

    it 'rejects a missing root' do
      expect do
        described_class.new(configuration: configuration, root: File.join(root, 'missing'))
      end.to raise_error(ArgumentError, /audit root is not a directory/)
    end
  end

  describe '#call' do
    let(:absolute_file) { File.join(root, 'app', 'sample.rb') }
    let(:absolute_site) do
      FiberAudit::Static::CallSite.new(
        path: absolute_file,
        line: 1,
        column: 0,
        receiver_source: nil,
        receiver_constant: nil,
        method_name: :puts,
        arguments: ["'sample'"],
        enclosing_symbol: nil,
        nesting: [],
        execution_context: nil,
        resolution: nil,
        confidence: :unknown
      )
    end
    let(:call_sites) { [absolute_site] }

    it 'orchestrates indexing, unchanged absolute extraction paths, contexts, and rules' do
      expect(FiberAudit::Static::SemanticIndex).to receive(:new)
        .with(root: root).and_return(semantic_index)
      expect(FiberAudit::Static::CallSiteExtractor).to receive(:new)
        .with(files: [absolute_file], semantic_index: semantic_index).and_return(extractor)
      expect(FiberAudit::Static::ExecutionContextResolver).to receive(:new)
        .with(workspace: semantic_index).and_return(context_resolver)
      expect(context_resolver).to receive(:resolve_all) do |call_sites:|
        expect(call_sites.map(&:path)).to eq(['app/sample.rb'])
        call_sites
      end
      expect(FiberAudit::Static::Rules::BuiltIns).to receive(:registry)
        .with(workspace: semantic_index, context_resolver: context_resolver)
        .and_return(registry)
      expect(rule).to receive(:analyze) do |call_sites:|
        expect(call_sites.map(&:path)).to eq(['app/sample.rb'])
        []
      end

      described_class.new(configuration: configuration, root: root).call
    end

    it 'returns deterministic coverage and frozen result arrays' do
      result = described_class.new(configuration: configuration, root: root).call

      expect(result.coverage).to eq(
        described_class::Coverage.new(analysed_files: 1, total_call_sites: 1, rules_run: 1)
      )
      expect(result.findings).to be_frozen
      expect(result.suppressed).to be_frozen
      expect(result.parse_errors).to be_frozen
      expect(result.status).to eq('NO_FINDINGS')
    end

    it 'relativizes parse error paths without treating them as fatal' do
      allow(extractor).to receive(:call).and_return(
        FiberAudit::Static::CallSiteExtractor::Result.new(
          call_sites: [],
          parse_errors: [FiberAudit::Static::CallSiteExtractor::ParseError.new(
            path: absolute_file, message: 'syntax error', line: 1
          )]
        )
      )

      result = described_class.new(configuration: configuration, root: root).call

      expect(result.parse_errors.first.path).to eq('app/sample.rb')
      expect(result.status).to eq('NO_FINDINGS')
    end
  end

  describe 'file expansion' do
    it 'sorts, deduplicates, excludes, and prevents include patterns escaping the root' do
      File.write(File.join(root, 'app', 'a.rb'), '# a')
      File.write(File.join(root, 'app', 'excluded.rb'), '# excluded')
      outside = File.join(File.dirname(root), 'outside.rb')
      File.write(outside, '# outside')
      config = FiberAudit::Configuration.new(
        static_include: ['app/**/*.rb', 'app/*.rb', '../outside.rb'],
        static_exclude: ['app/excluded.rb']
      )
      expected = [File.join(root, 'app', 'a.rb'), File.join(root, 'app', 'sample.rb')]

      expect(FiberAudit::Static::CallSiteExtractor).to receive(:new)
        .with(files: expected, semantic_index: semantic_index).and_return(extractor)

      described_class.new(configuration: config, root: root).call
    ensure
      FileUtils.rm_f(outside) if outside
    end

    it 'counts only regular Ruby files' do
      File.write(File.join(root, 'app', 'ignored.txt'), 'ignored')
      config = FiberAudit::Configuration.new(static_include: ['app/**/*'], static_exclude: [])

      result = described_class.new(configuration: config, root: root).call
      expect(result.coverage.analysed_files).to eq(1)
    end
  end

  describe 'suppressions' do
    let(:finding) { build_finding(path: 'app/sample.rb', line: 1) }
    let(:rule_findings) { [finding] }

    it 'applies inline suppressions using root-relative paths' do
      File.write(
        File.join(root, 'app', 'sample.rb'),
        "system('true') # fiber-audit:disable FA1001 -- accepted risk\n"
      )

      result = described_class.new(configuration: configuration, root: root).call

      expect(result.findings).to be_empty
      expect(result.suppressed).to eq([finding])
      expect(result.status).to eq('NO_FINDINGS')
    end

    it 'resolves and applies a YAML suppression path from the root' do
      File.write(
        File.join(root, 'suppressions.yml'),
        "suppressions:\n  - rule: FA1001\n    reason: accepted risk\n"
      )
      config = FiberAudit::Configuration.new(
        static_include: ['app/**/*.rb'],
        static_exclude: [],
        suppressions_path: 'suppressions.yml'
      )

      result = described_class.new(configuration: config, root: root).call
      expect(result.suppressed).to eq([finding])
    end

    it 'propagates missing suppression reasons as configuration errors' do
      File.write(
        File.join(root, 'app', 'sample.rb'),
        "system('true') # fiber-audit:disable FA1001\n"
      )

      expect do
        described_class.new(configuration: configuration, root: root).call
      end.to raise_error(FiberAudit::ConfigurationError, /missing reason/)
    end
  end

  describe 'minimum severity' do
    let(:rule_findings) do
      [build_finding(severity: :low), build_finding(severity: :info, operation: 'Mutex#try_lock')]
    end

    it 'excludes info findings at the default low threshold' do
      result = described_class.new(configuration: configuration, root: root).call

      expect(result.findings.map(&:severity)).to eq([:low])
      expect(result.status).to eq('PASS_WITH_WARNINGS')
    end

    it 'includes info findings when configured' do
      config = FiberAudit::Configuration.new(
        static_include: ['app/**/*.rb'], static_exclude: [], min_severity: :info
      )

      result = described_class.new(configuration: config, root: root).call
      expect(result.findings.map(&:severity)).to eq(%i[low info])
    end
  end

  describe 'status derivation' do
    subject(:status) do
      audit = described_class.new(configuration: configuration, root: root)
      audit.send(:determine_status, findings)
    end

    cases = {
      'FAIL for critical' => [{ severity: :critical }, 'FAIL'],
      'FAIL for high' => [{ severity: :high }, 'FAIL'],
      'REVIEW for medium' => [{ severity: :medium }, 'REVIEW'],
      'REVIEW for low confidence' => [{ severity: :low, confidence: :low }, 'REVIEW'],
      'REVIEW for unknown confidence' => [{ severity: :low, confidence: :unknown }, 'REVIEW'],
      'PASS_WITH_WARNINGS for low/high-confidence' => [{ severity: :low }, 'PASS_WITH_WARNINGS'],
      'PASS_WITH_WARNINGS for info/unknown-confidence' => [
        { severity: :info, confidence: :unknown }, 'PASS_WITH_WARNINGS'
      ],
      'NO_FINDINGS when empty' => [nil, 'NO_FINDINGS']
    }

    cases.each do |description, (attributes, expected)|
      context description do
        let(:findings) { attributes ? [build_finding(**attributes)] : [] }

        it { is_expected.to eq(expected) }
      end
    end

    it 'never emits unconditional PASS' do
      statuses = cases.values.map(&:last)
      expect(statuses).not_to include('PASS')
    end
  end

  def build_finding(
    severity: :high,
    confidence: :high,
    path: 'app/sample.rb',
    line: 1,
    operation: 'Kernel.system'
  )
    FiberAudit::Finding.new(
      rule_id: 'FA1001',
      title: 'Blocking subprocess call',
      category: :subprocess,
      severity: severity,
      confidence: confidence,
      location: FiberAudit::Location.new(path: path, line: line, column: 0),
      symbol: 'Sample#call',
      operation: operation,
      execution_context: :unknown,
      message: 'matched',
      evidence: [FiberAudit::Evidence.new(source: :static, message: 'matched')],
      remediation: 'avoid blocking work'
    )
  end
end
