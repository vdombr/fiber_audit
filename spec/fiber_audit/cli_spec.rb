# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/cli'
require 'json'
require 'stringio'
require 'tmpdir'
require 'fileutils'

RSpec.describe FiberAudit::CLI do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def run_cli(*args, cwd: Dir.pwd, output: stdout)
    described_class.start(args, stdout: output, stderr: stderr, cwd: cwd)
  end

  def no_findings_result
    audit_result(findings: [], status: 'NO_FINDINGS')
  end

  def warning_result
    finding = FiberAudit::Finding.new(
      rule_id: 'FA1003',
      title: 'Thread synchronization',
      category: :synchronization,
      severity: :low,
      confidence: :high,
      message: 'review synchronization',
      evidence: [FiberAudit::Evidence.new(source: :static, message: 'matched')]
    )
    audit_result(findings: [finding], status: 'PASS_WITH_WARNINGS')
  end

  def audit_result(findings:, status:)
    FiberAudit::Audit::Result.new(
      findings: findings,
      suppressed: [],
      parse_errors: [],
      coverage: FiberAudit::Audit::Coverage.new(
        analysed_files: 0,
        total_call_sites: 0,
        rules_run: 7
      ),
      status: status
    )
  end

  describe '.start' do
    it 'prints the version and returns zero' do
      expect(run_cli('version')).to eq(0)
      expect(stdout.string).to eq("fiber-audit #{FiberAudit::VERSION}\n")
    end

    it 'rejects unknown commands with exit code two' do
      expect(run_cli('unknown')).to eq(2)
      expect(stderr.string).to include('unknown command')
    end

    it 'prints help without exiting the process' do
      expect(run_cli('help')).to eq(0)
      expect(stdout.string).to include('Usage: fiber-audit')
    end
  end

  describe 'list-rules' do
    it 'lists all seven built-in rules without running an audit' do
      expect(FiberAudit::Audit).not_to receive(:new)

      expect(run_cli('list-rules')).to eq(0)
      expect(stdout.string.scan(/FA100[1-7]/)).to eq(%w[FA1001 FA1002 FA1003 FA1004 FA1005 FA1006 FA1007])
    end
  end

  describe 'explain' do
    it 'prints metadata, targets, and remediation' do
      expect(FiberAudit::Audit).not_to receive(:new)

      expect(run_cli('explain', 'FA1001')).to eq(0)
      expect(stdout.string).to include('FA1001', 'Kernel.system', 'Default severity: high')
      expect(stdout.string).to include(
        'Move long-running subprocess work outside the request path, or verify scheduler behaviour under load.'
      )
    end

    it 'returns two for a missing or unknown rule' do
      expect(run_cli('explain')).to eq(2)
      expect(run_cli('explain', 'FA9999')).to eq(2)
    end
  end

  describe 'static' do
    let(:fixtures) { File.expand_path('../fixtures/apps', __dir__) }

    it 'returns zero for the clean fixture' do
      root = File.join(fixtures, 'poro_clean')

      expect(run_cli('static', '--format', 'text', '--no-color', cwd: root)).to eq(0)
      expect(stdout.string).to include('NO_FINDINGS')
      expect(stdout.string).to include(FiberAudit::Reporters::Schema::DISCLAIMER)
    end

    it 'returns one and reports all rules for the blocker fixture' do
      root = File.join(fixtures, 'rails_blockers')

      expect(run_cli('static', '--format', 'json', cwd: root)).to eq(1)
      report = JSON.parse(stdout.string)
      expect(report.fetch('findings').map { |finding| finding.fetch('rule_id') }.uniq)
        .to eq(%w[FA1001 FA1002 FA1003 FA1004 FA1005 FA1006 FA1007])
      expect(report.fetch('status')).to eq('FAIL')
    end

    it 'defaults to JSON when stdout is not a TTY' do
      root = File.join(fixtures, 'poro_clean')
      audit = instance_double(FiberAudit::Audit, call: no_findings_result)
      allow(FiberAudit::Audit).to receive(:new).and_return(audit)

      expect(run_cli('static', cwd: root)).to eq(0)
      expect(JSON.parse(stdout.string).fetch('status')).to eq('NO_FINDINGS')
    end

    it 'defaults to text and enables color when stdout is a TTY' do
      root = File.join(fixtures, 'poro_clean')
      tty_output = StringIO.new
      allow(tty_output).to receive(:tty?).and_return(true)
      audit = instance_double(FiberAudit::Audit, call: no_findings_result)
      allow(FiberAudit::Audit).to receive(:new).and_return(audit)

      expect(run_cli('static', cwd: root, output: tty_output)).to eq(0)
      expect(tty_output.string).to start_with("FiberAudit #{FiberAudit::VERSION}")
    end

    it 'applies the command-line minimum severity override without losing runtime policy' do
      root = File.join(fixtures, 'poro_clean')
      policy = FiberAudit::Runtime::Policy.new(sampling_rate: 0.75)
      allow(FiberAudit::Configuration).to receive(:load)
        .and_return(FiberAudit::Configuration.new(runtime_policy: policy))
      audit = instance_double(FiberAudit::Audit, call: no_findings_result)
      expect(FiberAudit::Audit).to receive(:new) do |configuration:, root:|
        expect(configuration.min_severity).to eq(:critical)
        expect(configuration.runtime_policy).to equal(policy)
        expect(root).to eq(File.realpath(File.join(fixtures, 'poro_clean')))
        audit
      end

      expect(run_cli('static', '--min-severity', 'critical', cwd: root)).to eq(0)
    end

    it 'returns one for PASS_WITH_WARNINGS when a finding meets the threshold' do
      root = File.join(fixtures, 'poro_clean')
      audit = instance_double(FiberAudit::Audit, call: warning_result)
      allow(FiberAudit::Audit).to receive(:new).and_return(audit)

      expect(run_cli('static', '--format', 'json', cwd: root)).to eq(1)
      expect(JSON.parse(stdout.string).fetch('status')).to eq('PASS_WITH_WARNINGS')
    end

    it 'returns two for malformed configuration' do
      Dir.mktmpdir do |root|
        File.write(File.join(root, 'Gemfile'), "source 'https://rubygems.org'\n")
        File.write(File.join(root, '.fiber-audit.yml'), "unknown: true\n")

        expect(run_cli('static', cwd: root)).to eq(2)
        expect(stderr.string).to include('unknown configuration key')
      end
    end

    it 'returns two for an explicitly missing configuration file' do
      root = File.join(fixtures, 'poro_clean')

      expect(run_cli('static', '--config', 'missing.yml', cwd: root)).to eq(2)
      expect(stderr.string).to include('configuration file does not exist')
    end

    it 'writes only a confirmation to stdout with --out' do
      root = File.join(fixtures, 'poro_clean')
      audit = instance_double(FiberAudit::Audit, call: no_findings_result)
      allow(FiberAudit::Audit).to receive(:new).and_return(audit)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'audit.json')

        expect(run_cli('static', '--out', path, cwd: root)).to eq(0)
        expect(stdout.string).to eq("Report written to #{path}\n")
        expect(JSON.parse(File.read(path)).fetch('status')).to eq('NO_FINDINGS')
      end
    end

    it 'returns two for invalid options' do
      expect(run_cli('static', '--format', 'xml')).to eq(2)
      expect(stderr.string).to include('invalid argument')
    end
  end
end
