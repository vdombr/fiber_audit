# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, Metrics/AbcSize

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'
require 'spec_helper'
require_relative '../support/native_gvl_fixture'

RSpec.describe 'native GVL process-progress conformance' do
  PROJECT_ROOT = File.expand_path('../..', __dir__).freeze
  REQUIRED_FIXTURE_KEY = 'FIBER_AUDIT_REQUIRE_NATIVE_GVL_FIXTURE'

  before(:context) do
    @native_build = FiberAuditSpecSupport::NativeGVLFixture.build
  end

  after(:context) do
    @native_build&.cleanup
  end

  it 'distinguishes native work that retains and releases the GVL' do
    require_native_fixture!

    held = run_mode('hold_gvl')
    released = run_mode('release_gvl')

    expect(held.fetch(:status)).to be_success, held.fetch(:stderr)
    expect(released.fetch(:status)).to be_success, released.fetch(:stderr)
    expect(held.fetch(:kinds)).to include(
      'process_progress_stall_started',
      'process_progress_stall_completed'
    )
    expect(released.fetch(:kinds)).not_to include('process_progress_stall_started')
    expect(held.fetch(:parent).first.dig('payload', 'process_role')).to eq('parent_monitor')
    expect(released.fetch(:parent).first.dig('payload', 'process_role')).to eq('parent_monitor')
    expect(held.fetch(:bytes)).not_to include(
      'native-gvl-command-private', @native_build.require_path
    )
    expect(released.fetch(:bytes)).not_to include(
      'native-gvl-command-private', @native_build.require_path
    )
  end

  def require_native_fixture!
    return if @native_build.available?

    raise @native_build.reason if ENV[REQUIRED_FIXTURE_KEY] == '1'

    skip "native GVL fixture unavailable locally: #{@native_build.reason}"
  end

  def run_mode(mode)
    Dir.mktmpdir("fiber-audit-#{mode}") do |root|
      File.write(File.join(root, 'Gemfile'), "source 'https://rubygems.org'\n")
      File.write(File.join(root, '.fiber-audit.yml'), configuration)
      output = File.join(root, 'sessions')
      script = <<~RUBY
        require ARGV.fetch(0)
        private_command_marker = 'native-gvl-command-private'
        FiberAuditNativeGVL.public_send(ARGV.fetch(1), Integer(ARGV.fetch(2), 10))
        sleep 0.08
        private_command_marker
      RUBY
      command = [
        RbConfig.ruby,
        "-I#{File.join(PROJECT_ROOT, 'lib')}",
        File.join(PROJECT_ROOT, 'bin/fiber-audit'),
        'runtime', '--out', output, '--',
        RbConfig.ruby, '-e', script,
        @native_build.require_path, mode, '180'
      ]
      stdout, stderr, status = capture_bounded(command, root)
      records = Dir.glob(File.join(output, '*.jsonl')).map do |path|
        File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      end
      parent = records.find do |session|
        session.first.dig('payload', 'process_role') == 'parent_monitor'
      end
      raise 'parent-monitor session was not written' unless parent

      {
        stdout: stdout,
        stderr: stderr,
        status: status,
        parent: parent,
        kinds: parent.filter_map { |record| record.dig('payload', 'kind') },
        bytes: Dir.glob(File.join(output, '*.jsonl')).map { |path| File.binread(path) }.join
      }.freeze
    end
  end

  def configuration
    <<~YAML
      runtime:
        sampling:
          rate: 1.0
        process_progress:
          enabled: true
          heartbeat_interval_ms: 10
          stall_threshold_ms: 60
    YAML
  end

  def capture_bounded(command, directory)
    stdin = stdout = stderr = wait_thread = nil
    output_reader = error_reader = nil
    stdin, stdout, stderr, wait_thread = Open3.popen3(*command, chdir: directory)
    stdin.close
    output_reader = Thread.new { stdout.read }
    error_reader = Thread.new { stderr.read }
    status = Timeout.timeout(10) { wait_thread.value }
    [output_reader.value, error_reader.value, status]
  rescue Timeout::Error
    begin
      Process.kill('TERM', wait_thread.pid) if wait_thread
    rescue Errno::ESRCH
      nil
    end
    wait_thread&.value
    raise
  ensure
    [stdin, stdout, stderr].compact.each do |io|
      io.close unless io.closed?
    rescue IOError
      nil
    end
    output_reader&.kill
    error_reader&.kill
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, Metrics/AbcSize
