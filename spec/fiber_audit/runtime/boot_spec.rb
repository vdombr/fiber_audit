# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fiber_audit/runtime/environment'

RSpec.describe 'FiberAudit runtime boot' do
  let(:launch_id) { '123e4567-e89b-42d3-a456-426614174000' }

  def activation_environment(root, output, fail_open: true)
    policy = FiberAudit::Runtime::Policy.new(sampling_rate: 1.0, fail_open: fail_open)
    settings = FiberAudit::Runtime::Environment.build(
      policy: policy,
      output_directory: output,
      project_root: root,
      launch_id: launch_id
    )
    FiberAudit::Runtime::Environment.child_environment(settings: settings)
  end

  def run_child(environment, script, *arguments)
    Open3.capture3(environment, RbConfig.ruby, '-e', script, *arguments)
  end

  def session_records(output)
    files = Dir.glob(File.join(output, '*.jsonl'))
    [files, files.map { |path| File.readlines(path, chomp: true).map { |line| JSON.parse(line) } }]
  end

  it 'is side-effect free without explicit activation' do
    Dir.mktmpdir do |root|
      script = <<~RUBY
        require 'fiber_audit/runtime/boot'
        puts FiberAudit::Runtime::Boot.activated?
        puts defined?(FiberAudit::Static).nil?
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script, chdir: root)

      expect(status).to be_success, stderr
      expect(stdout.lines.map(&:strip)).to eq(%w[false true])
      expect(Dir.children(root)).to be_empty
    end
  end

  it 'writes exactly one completed start/end session without changing exit status' do
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      environment = activation_environment(root, output)

      stdout, stderr, status = run_child(environment, 'puts "application output"; exit 7')
      files, sessions = session_records(output)

      expect(status.exitstatus).to eq(7), stderr
      expect(stdout).to eq("application output\n")
      expect(files.size).to eq(1)
      expect(sessions.first.map { |record| record['record_type'] }).to eq(%w[session_start session_end])
      expect(sessions.first.last.dig('payload', 'status')).to eq('completed')
    end
  end

  it 'marks unhandled exceptions aborted without recording exception or argument values' do
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      environment = activation_environment(root, output)
      secret = 'token-super-secret-123'

      _stdout, _stderr, status = run_child(environment, 'raise "boom"', '--', secret)
      files, sessions = session_records(output)

      expect(status).not_to be_success
      expect(sessions.first.last.dig('payload', 'status')).to eq('aborted')
      expect(File.binread(files.first)).not_to include('boom', secret)
    end
  end

  it 'fails open for malformed activation and fails closed when requested' do
    Dir.mktmpdir do |root|
      base = {
        FiberAudit::Runtime::Environment::ACTIVATION_KEY => '1',
        FiberAudit::Runtime::Environment::SETTINGS_KEY => 'malformed',
        'RUBYOPT' => FiberAudit::Runtime::Environment::BOOT_REQUIRE,
        'RUBYLIB' => File.expand_path('lib', Dir.pwd)
      }

      stdout, stderr, status = run_child(
        base.merge(FiberAudit::Runtime::Environment::FAILURE_MODE_KEY => 'open'),
        'puts "ran"'
      )
      expect(status).to be_success, stderr
      expect(stdout).to eq("ran\n")

      _stdout, _stderr, closed_status = run_child(
        base.merge(FiberAudit::Runtime::Environment::FAILURE_MODE_KEY => 'closed'),
        'puts "must not run"'
      )
      expect(closed_status).not_to be_success
      expect(root).to be_a(String)
    end
  end

  it 'creates distinct noninterleaved sessions for forked Ruby processes' do
    skip 'fork is unavailable' unless Process.respond_to?(:fork)

    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      environment = activation_environment(root, output)
      script = 'pid = fork { exit 0 }; Process.wait(pid)'

      _stdout, stderr, status = run_child(environment, script)
      files, sessions = session_records(output)

      expect(status).to be_success, stderr
      expect(files.size).to eq(2)
      expect(sessions.map { |records| records.map { |record| record['record_type'] } })
        .to all(eq(%w[session_start session_end]))
      expect(sessions.map { |records| records.first['session_id'] }.uniq.size).to eq(2)
    end
  end
end
