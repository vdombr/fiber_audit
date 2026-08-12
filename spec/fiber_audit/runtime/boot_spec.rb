# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fiber_audit/runtime/environment'

RSpec.describe 'FiberAudit runtime boot' do
  let(:launch_id) { '123e4567-e89b-42d3-a456-426614174000' }

  def activation_environment(root, output, fail_open: true, watchdog: nil, probes: false)
    policy = FiberAudit::Runtime::Policy.new(sampling_rate: 1.0, fail_open: fail_open)
    settings = FiberAudit::Runtime::Environment.build(
      policy: policy,
      output_directory: output,
      project_root: File.realpath(root),
      launch_id: launch_id
    )
    FiberAudit::Runtime::Environment.child_environment(
      settings: settings,
      watchdog_policy: watchdog,
      probes_enabled: probes
    )
  end

  def run_child(environment, script, *arguments)
    Open3.capture3(environment, RbConfig.ruby, '-e', script, *arguments)
  end

  def run_file_child(environment, path, *arguments)
    Open3.capture3(environment, RbConfig.ruby, path, *arguments)
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
      lib_path = File.expand_path('../../../lib', __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{lib_path}", '-e', script, chdir: root)

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

  it 'records explicit absent and unsupported scheduler states' do
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      watchdog = FiberAudit::Runtime::WatchdogPolicy.new

      _stdout, stderr, status = run_child(
        activation_environment(root, output, watchdog: watchdog),
        'exit 0'
      )
      expect(status).to be_success, stderr
      _files, sessions = session_records(output)
      kinds = sessions.first.filter_map do |record|
        record.dig('payload', 'kind') if record['record_type'] == 'event'
      end
      expect(kinds).to eq(%w[watchdog_absent])

      frozen_scheduler = <<~RUBY
        class FrozenScheduler
          def block(*) = true
          def unblock(*) = nil
          def io_wait(*) = 0
          def kernel_sleep(*) = 0
          def close = nil
        end
        Fiber.set_scheduler(FrozenScheduler.new.freeze)
      RUBY
      _stdout, stderr, status = run_child(
        activation_environment(root, output, watchdog: watchdog),
        frozen_scheduler
      )
      expect(status).to be_success, stderr
      _files, sessions = session_records(output)
      unsupported = sessions.last.filter_map do |record|
        record.dig('payload', 'kind') if record['record_type'] == 'event'
      end
      expect(unsupported).to include('watchdog_unsupported')
    end
  end

  it 'distinguishes scheduler-friendly waiting from a deliberately blocked scheduler' do
    scheduler_source = <<~RUBY
      class RuntimeTestScheduler
        def initialize
          @waiting = []
        end

        def fiber(&block)
          fiber = Fiber.new(blocking: false, &block)
          fiber.resume
          drain_ready
          fiber
        end

        def kernel_sleep(duration = nil)
          @waiting << [monotonic + (duration || 0), Fiber.current]
          Fiber.yield
          0
        end

        def io_wait(_io, _events, timeout = nil)
          kernel_sleep(timeout || 0.001)
          0
        end

        def block(_blocker, timeout = nil)
          kernel_sleep(timeout || 0.001)
          true
        end

        def unblock(_blocker, fiber)
          fiber.resume if fiber.alive?
        end

        def close
          until @waiting.empty?
            drain_ready
            break if @waiting.empty?

            delay = @waiting.map(&:first).min - monotonic
            ::Kernel.sleep(delay) if delay.positive?
          end
        end

        private

        def drain_ready
          ready, @waiting = @waiting.partition { |deadline, _fiber| deadline <= monotonic }
          ready.each { |_deadline, fiber| fiber.resume if fiber.alive? }
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      Fiber.set_scheduler(RuntimeTestScheduler.new)
      Fiber.schedule do
        if ARGV.fetch(0) == 'blocked'
          IO.select(nil, nil, nil, 0.18)
        else
          sleep 0.05
        end
      end
      ::Kernel.sleep(0.04)
    RUBY

    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      scenario = File.join(root, 'scenario.rb')
      File.write(scenario, scheduler_source)
      watchdog = FiberAudit::Runtime::WatchdogPolicy.new(
        heartbeat_interval_ms: 10,
        stall_threshold_ms: 50,
        max_frames: 5
      )
      environment = activation_environment(root, output, watchdog: watchdog)

      _stdout, stderr, friendly = run_file_child(environment, scenario, 'friendly')
      expect(friendly).to be_success, stderr
      _stdout, stderr, blocked = run_file_child(environment, scenario, 'blocked')
      expect(blocked).to be_success, stderr

      _files, sessions = session_records(output)
      kinds = sessions.map do |records|
        records.filter_map { |record| record.dig('payload', 'kind') if record['record_type'] == 'event' }
      end
      friendly_kinds, blocked_kinds = kinds.sort_by { |entries| entries.count('scheduler_stall_started') }
      expect(friendly_kinds).not_to include('scheduler_stall_started')
      expect(blocked_kinds.count('scheduler_stall_started')).to eq(1)
      expect(blocked_kinds.count('scheduler_stall_completed')).to eq(1)

      frame_paths = sessions.flatten.filter_map do |record|
        record.dig('payload', 'location', 'path') if record.dig('payload', 'kind') == 'scheduler_stall_frame'
      end
      expect(frame_paths.size).to be <= 5
      expect(frame_paths).to all(eq('scenario.rb'))
    end
  end

  it 'records targeted project operations with late loading and no sensitive values' do
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      scenario = File.join(root, 'scenario.rb')
      secret = 'stage5-boot-command-secret'
      File.write(
        scenario,
        <<~RUBY
          require 'rbconfig'
          Thread.current.thread_variable_set(:stage5_secret_key, '#{secret}')
          Mutex.new.synchronize { :ok }
          IO.select(nil, nil, nil, 0.001)
          system(RbConfig.ruby, '-e', 'exit 0', '#{secret}')
          require 'open3'
          Open3.capture2(RbConfig.ruby, '-e', 'puts :ok', '#{secret}')
          require 'monitor'
          Monitor.new.synchronize { :ok }
          require 'socket'
          Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0).close
          require 'net/http'
          require 'open-uri'
          raise 'late HTTP hooks missing' unless
            Net::HTTP.ancestors.include?(FiberAudit::Runtime::Probes::HTTP::NetHTTPInstanceHook) &&
            URI.singleton_class.ancestors.include?(FiberAudit::Runtime::Probes::HTTP::URIHook)
        RUBY
      )
      environment = activation_environment(
        root,
        output,
        watchdog: FiberAudit::Runtime::WatchdogPolicy.new(enabled: false),
        probes: true
      )

      _stdout, stderr, status = run_file_child(environment, scenario)
      files, sessions = session_records(output)
      project_session = sessions.find do |records|
        records.any? { |record| record.dig('payload', 'location', 'path') == 'scenario.rb' }
      end
      operations = project_session.filter_map { |record| record.dig('payload', 'operation') }

      expect(status).to be_success, stderr
      expect(operations).to include(
        'Thread.thread_variable_set', 'Mutex#synchronize', 'IO.select',
        'Kernel.system', 'Open3.capture2', 'Monitor#synchronize', 'Socket.new'
      )
      expect(files.map { |path| File.binread(path) }.join).not_to include(secret, 'stage5_secret_key')
      expect(project_session.filter_map { |record| record.dig('payload', 'location', 'path') }.uniq)
        .to eq(['scenario.rb'])
    end
  end

  it 'rebinds watchdog state into distinct sessions after a fork' do
    skip 'fork is unavailable' unless Process.respond_to?(:fork)

    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      environment = activation_environment(
        root,
        output,
        watchdog: FiberAudit::Runtime::WatchdogPolicy.new
      )

      _stdout, stderr, status = run_child(environment, 'pid = fork { exit 0 }; Process.wait(pid)')
      _files, sessions = session_records(output)

      expect(status).to be_success, stderr
      expect(sessions.size).to eq(2)
      expect(sessions.map { |records| records.first['session_id'] }.uniq.size).to eq(2)
      expect(sessions).to all(satisfy do |records|
        records.any? { |record| record.dig('payload', 'kind') == 'watchdog_absent' }
      end)
    end
  end

  it 'honors fail-open and fail-closed modes for malformed watchdog activation' do
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)

      open_environment = activation_environment(
        root,
        output,
        watchdog: FiberAudit::Runtime::WatchdogPolicy.new
      ).merge(FiberAudit::Runtime::Environment::WATCHDOG_SETTINGS_KEY => 'malformed')
      stdout, stderr, status = run_child(open_environment, 'puts "ran"')
      expect(status).to be_success, stderr
      expect(stdout).to eq("ran\n")

      closed_environment = activation_environment(
        root,
        output,
        fail_open: false,
        watchdog: FiberAudit::Runtime::WatchdogPolicy.new
      ).merge(FiberAudit::Runtime::Environment::WATCHDOG_SETTINGS_KEY => 'malformed')
      _stdout, _stderr, status = run_child(closed_environment, 'puts "must not run"')
      expect(status).not_to be_success
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
