# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fiber_audit/runtime/environment'

RSpec.describe 'targeted runtime probe integration' do
  let(:launch_id) { '123e4567-e89b-42d3-a456-426614174000' }

  def activation_environment(
    root,
    output,
    watchdog: FiberAudit::Runtime::WatchdogPolicy.new(enabled: false),
    liveness: nil
  )
    policy = FiberAudit::Runtime::Policy.new(
      sampling_rate: 1.0,
      max_events_per_second: 1_000,
      max_events_per_session: 10_000
    )
    settings = FiberAudit::Runtime::Environment.build(
      policy: policy,
      output_directory: output,
      project_root: File.realpath(root),
      launch_id: launch_id
    )
    FiberAudit::Runtime::Environment.child_environment(
      settings: settings,
      watchdog_policy: watchdog,
      operation_liveness_policy: liveness,
      probes_enabled: true
    )
  end

  def run_file(environment, path, *arguments)
    Open3.capture3(environment, RbConfig.ruby, path, *arguments)
  end

  def sessions(output)
    Dir.glob(File.join(output, '*.jsonl')).map do |path|
      [path, File.readlines(path, chomp: true).map { |line| JSON.parse(line) }]
    end
  end

  it 'associates a deliberate scheduler stall with the active targeted operation sequence' do
    scheduler_source = <<~RUBY
      class Stage5Scheduler
        def initialize = @waiting = []

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

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      Fiber.set_scheduler(Stage5Scheduler.new)
      Fiber.schedule { IO.select(nil, nil, nil, 0.18) }
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

      _stdout, stderr, status = run_file(activation_environment(root, output, watchdog: watchdog), scenario)
      records = sessions(output).first.last
      operation = records.find do |record|
        record.dig('payload', 'operation') == 'IO.select' &&
          record.dig('payload', 'kind') == 'operation_completed'
      end
      overlap = records.find { |record| record.dig('payload', 'kind') == 'scheduler_stall_operation_overlap' }
      stall = records.find { |record| record.dig('payload', 'kind') == 'scheduler_stall_started' }

      expect(status).to be_success, stderr
      expect(operation).not_to be_nil
      expect(stall.dig('payload', 'measurements', 'active_operation_count')).to eq(1)
      expect(overlap.dig('payload', 'operation')).to eq('IO.select')
      expect(overlap.dig('payload', 'measurements', 'operation_sequence'))
        .to eq(operation.dig('payload', 'measurements', 'operation_sequence'))
      expect(records.count { |record| record.dig('payload', 'kind') == 'scheduler_stall_completed' }).to eq(1)
    end
  end

  it 'observes a long active operation while scheduler heartbeats remain healthy' do
    scheduler_source = <<~RUBY
      class HealthyScheduler
        def initialize = @waiting = []

        def fiber(&block)
          fiber = Fiber.new(blocking: false, &block)
          fiber.resume
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

        def run_for(duration)
          deadline = monotonic + duration
          while monotonic < deadline
            drain_ready
            ::Kernel.sleep(0.001)
          end
          drain_ready
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

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      scheduler = HealthyScheduler.new
      Fiber.set_scheduler(scheduler)
      Fiber.schedule { Mutex.new.synchronize { sleep 0.08 } }
      scheduler.run_for(0.12)
    RUBY

    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      scenario = File.join(root, 'healthy_liveness_scenario.rb')
      File.write(scenario, scheduler_source)
      watchdog = FiberAudit::Runtime::WatchdogPolicy.new(
        heartbeat_interval_ms: 10,
        stall_threshold_ms: 50,
        max_frames: 0
      )
      liveness = FiberAudit::Runtime::OperationLivenessPolicy.new(
        poll_interval_ms: 5,
        long_active_threshold_ms: 20
      )

      _stdout, stderr, status = run_file(
        activation_environment(root, output, watchdog: watchdog, liveness: liveness),
        scenario
      )
      records = sessions(output).first.last
      kinds = records.filter_map { |record| record.dig('payload', 'kind') }
      starts = records.select do |record|
        record.dig('payload', 'kind') == 'operation_long_active_started' &&
          record.dig('payload', 'operation') == 'Mutex#synchronize'
      end
      completions = records.select do |record|
        record.dig('payload', 'kind') == 'operation_long_active_completed' &&
          record.dig('payload', 'operation') == 'Mutex#synchronize'
      end

      expect(status).to be_success, stderr
      expect(kinds).to include('watchdog_active', 'operation_liveness_active')
      expect(kinds).not_to include('scheduler_stall_started')
      expect(starts.size).to eq(1)
      expect(completions.size).to eq(1)
      expect(completions.first.dig('payload', 'measurements', 'operation_finished')).to be(true)
      expect(completions.first.dig('payload', 'measurements', 'long_active_sequence'))
        .to eq(starts.first.dig('payload', 'measurements', 'long_active_sequence'))
    end
  end

  it 'installs and executes HTTP/OpenURI hooks after a late require' do
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      scenario = File.join(root, 'late_http_scenario.rb')
      secret = 'late-open-uri-response-secret'
      File.write(
        scenario,
        <<~RUBY
          raise 'OpenURI loaded too early' if defined?(OpenURI)
          require 'socket'
          server = TCPServer.new('127.0.0.1', 0)
          responder = Thread.new do
            client = server.accept
            loop do
              line = client.gets
              break if line.nil? || line == "\\r\\n"
            end
            body = '#{secret}'
            client.write("HTTP/1.1 200 OK\\r\\nContent-Length: \#{body.bytesize}\\r\\nConnection: close\\r\\n\\r\\n\#{body}")
            client.close
          end
          require 'open-uri'
          url = "http://127.0.0.1:\#{server.addr[1]}/late-stage5-secret"
          raise 'response changed' unless URI.open(url, &:read) == '#{secret}'
          responder.value
          server.close
        RUBY
      )

      _stdout, stderr, status = run_file(activation_environment(root, output), scenario)
      records = sessions(output).first.last
      event = records.find { |record| record.dig('payload', 'operation') == 'URI.open' }
      bytes = sessions(output).map { |path, _records| File.binread(path) }.join

      expect(status).to be_success, stderr
      expect(event.dig('payload', 'kind')).to eq('operation_completed')
      expect(event.dig('payload', 'location', 'path')).to eq('late_http_scenario.rb')
      expect(bytes).not_to include(secret, 'late-stage5-secret', '127.0.0.1')
    end
  end

  it 'writes a bounded start event before successful exec and leaves the prior session truncated' do
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      scenario = File.join(root, 'exec_scenario.rb')
      secret = 'exec-stage5-command-secret'
      File.write(
        scenario,
        "require 'rbconfig'; exec(RbConfig.ruby, '-e', 'exit 7', #{secret.inspect})\n"
      )

      _stdout, _stderr, status = run_file(activation_environment(root, output), scenario)
      streams = sessions(output)
      started = streams.find do |_path, records|
        records.any? { |record| record.dig('payload', 'operation') == 'Kernel.exec' }
      end
      _path, records = started

      expect(status.exitstatus).to eq(7)
      expect(records.any? { |record| record['record_type'] == 'session_end' }).to be(false)
      expect(records.find { |record| record.dig('payload', 'operation') == 'Kernel.exec' }
               .dig('payload', 'kind')).to eq('operation_started')
      expect(streams.map { |path, _records| File.binread(path) }.join).not_to include(secret)
    end
  end

  it 'rebinds probes and active-operation state into a distinct forked session' do
    skip 'fork is unavailable' unless Process.respond_to?(:fork)

    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      scenario = File.join(root, 'fork_scenario.rb')
      File.write(
        scenario,
        <<~RUBY
          pid = fork do
            Thread.current.thread_variable_set(:stage5_fork_probe, :child)
          end
          Process.wait(pid)
          Thread.current.thread_variable_set(:stage5_fork_probe, :parent)
        RUBY
      )

      _stdout, stderr, status = run_file(activation_environment(root, output), scenario)
      streams = sessions(output)

      expect(status).to be_success, stderr
      expect(streams.size).to eq(2)
      expect(streams.map { |_path, records| records.first['session_id'] }.uniq.size).to eq(2)
      operation_sets = streams.map do |_path, records|
        records.filter_map do |record|
          next unless record.dig('payload', 'operation')

          [
            record.dig('payload', 'operation'),
            record.dig('payload', 'location', 'line'),
            record.dig('payload', 'measurements', 'operation_sequence'),
            record.dig('payload', 'kind')
          ]
        end
      end
      counts = operation_sets.map do |operations|
        operations.count { |operation, _line, _sequence, _kind| operation == 'Thread.thread_variable_set' }
      end
      expect(counts).to eq([1, 1]), operation_sets.inspect
      expect(streams.map { |path, _records| File.binread(path) }.join).not_to include('stage5_fork_probe')
    end
  end
end
