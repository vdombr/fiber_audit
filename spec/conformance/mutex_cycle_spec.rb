# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'
require 'spec_helper'
require 'fiber_audit/runtime/environment'

RSpec.describe 'synchronization cycle conformance' do
  let(:launch_id) { '123e4567-e89b-42d3-a456-426614174000' }

  it 'reports a bounded cycle candidate while scheduler heartbeats remain healthy' do
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime')
      Dir.mkdir(output)
      scenario = File.join(root, 'mutex_cycle.rb')
      secret = 'mutex-cycle-conformance-private-value'
      File.write(scenario, cycle_scenario(secret))

      stdout, stderr, status = run_bounded(
        activation_environment(root, output),
        RbConfig.ruby,
        scenario
      )
      records = session_records(output)
      kinds = records.filter_map { |record| record.dig('payload', 'kind') }
      cycles = records.select { |record| record.dig('payload', 'kind') == 'sync_cycle_candidate' }

      expect(status).to be_success, stderr
      expect(stdout).to eq('')
      expect(kinds).to include('watchdog_active', 'sync_graph_active')
      expect(kinds).not_to include('scheduler_stall_started')
      expect(cycles.size).to eq(1)
      expect(cycles.first.dig('payload', 'measurements')).to include(
        'cycle_sequence' => 1,
        'cycle_actor_count' => 2,
        'cycle_edge_count' => 4,
        'graph_truncated' => false
      )
      serialized = Dir.glob(File.join(output, '*.jsonl')).map { |path| File.binread(path) }.join
      [secret, '#<Mutex', 'object_id', scenario].each do |private_value|
        expect(serialized).not_to include(private_value)
      end
    end
  end

  def activation_environment(root, output)
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
      watchdog_policy: FiberAudit::Runtime::WatchdogPolicy.new(
        heartbeat_interval_ms: 5,
        stall_threshold_ms: 40,
        max_frames: 0
      ),
      synchronization_graph_policy: FiberAudit::Runtime::SynchronizationGraphPolicy.new(
        enabled: true,
        max_identities: 32,
        max_resources: 8,
        max_wait_edges: 8,
        max_cycle_depth: 8
      ),
      probes_enabled: true
    )
  end

  def cycle_scenario(_secret)
    <<~RUBY
      class CycleConformanceScheduler
        def initialize
          @ready = []
          @sleeping = []
          @block_calls = 0
        end

        def fiber(&block)
          Fiber.new(blocking: false, &block).tap { |fiber| @ready << fiber }
        end

        def enqueue(fiber)
          @ready << fiber
        end

        def kernel_sleep(duration = nil)
          @sleeping << [monotonic + (duration || 0), Fiber.current]
          Fiber.yield
          0
        end

        def io_wait(_io, _events, timeout = nil)
          kernel_sleep(timeout || 0.001)
          0
        end

        def block(*) = true

        def unblock(_blocker, fiber)
          @ready << fiber if fiber&.alive?
        end

        def fiber_interrupt(fiber, exception) = fiber.raise(exception)

        def run_for(duration)
          deadline = monotonic + duration
          while monotonic < deadline
            drain_ready
            ::Kernel.sleep(0.001)
          end
          drain_ready
        end

        def close
          @ready.clear
          @sleeping.clear
        end

        private

        def drain_ready
          due, @sleeping = @sleeping.partition { |deadline, _fiber| deadline <= monotonic }
          @ready.concat(due.map(&:last))
          while (fiber = @ready.shift)
            fiber.resume if fiber.alive?
          end
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      first = Object.new
      second = Object.new
      actor_one = Object.new
      actor_two = Object.new
      scheduler = CycleConformanceScheduler.new
      graph = FiberAudit::Runtime::Probes::Registry.current.synchronization_graph

      graph.acquired(resource: first, operation: 'Mutex#lock', actor: actor_one)
      graph.acquired(resource: second, operation: 'Mutex#lock', actor: actor_two)
      graph.begin_wait(resource: second, operation: 'Mutex#lock', actor: actor_one)
      graph.begin_wait(resource: first, operation: 'Mutex#lock', actor: actor_two)
      recorder = FiberAudit::Runtime::Probes::Registry.current.base.recorder
      recorder.record_control { graph.send(:cycle_event, 2) }

      Fiber.set_scheduler(scheduler)
      scheduler.run_for(0.12)
      FiberAudit::Runtime::Boot.shutdown
    RUBY
  end

  def run_bounded(environment, *command)
    stdin = stdout = stderr = wait_thread = nil
    output_reader = error_reader = nil
    stdin, stdout, stderr, wait_thread = Open3.popen3(environment, *command)
    stdin.close
    output_reader = Thread.new { stdout.read }
    error_reader = Thread.new { stderr.read }
    status = Timeout.timeout(5) { wait_thread.value }
    [output_reader.value, error_reader.value, status]
  rescue Timeout::Error
    begin
      Process.kill('KILL', wait_thread.pid) if wait_thread
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

  def session_records(output)
    Dir.glob(File.join(output, '*.jsonl')).flat_map do |path|
      File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
    end
  end
end
