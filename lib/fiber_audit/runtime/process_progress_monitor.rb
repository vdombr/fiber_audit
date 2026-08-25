# frozen_string_literal: true

require 'securerandom'
require_relative 'clock'
require_relative 'environment'
require_relative 'event'
require_relative 'jsonl/writer'
require_relative 'process_progress_policy'
require_relative 'process_progress_protocol'
require_relative 'recorder'
require_relative 'sampler'
require_relative 'session'

module FiberAudit
  module Runtime
    # Parent-owned, bounded observer for scalar progress frames from audited Ruby
    # processes. Silence is temporal evidence only; it is not a causality claim.
    # Parent monitor is a stable lifecycle and bounded-state ownership boundary.
    # rubocop:disable Metrics/ClassLength
    class ProcessProgressMonitor
      SOURCE = :process_progress_monitor
      STOP_TIMEOUT_SECONDS = 1
      READ_WAIT_SECONDS = 0.01
      STATES = %i[active unsupported stopped].freeze

      ProcessState = Data.define(
        :pid, :generation, :sequence, :child_monotonic_ns,
        :observed_monotonic_ns, :stalled
      )

      attr_reader :policy, :settings, :reader, :recorder, :output_path, :state

      def self.start(...) = new(...)

      def initialize(
        policy:, settings:, reader:, clock: Clock.new,
        session_id_source: SecureRandom.method(:uuid), pid_source: Process.method(:pid),
        writer_factory: JSONL::Writer.method(:open), random: Sampler::RANDOM_SOURCE,
        thread_factory: ->(&block) { Thread.new(&block) }
      )
        validate_dependencies!(policy, settings, reader, clock, session_id_source,
                               pid_source, writer_factory, random, thread_factory)
        @policy = policy
        @settings = settings
        @reader = reader
        @clock = clock
        @session_id_source = session_id_source
        @pid_source = pid_source
        @writer_factory = writer_factory
        @random = random
        @thread_factory = thread_factory
        @owner_pid = current_pid
        @decoder = ProcessProgressProtocol::Decoder.new(max_buffer_bytes: policy.max_buffer_bytes)
        @mutex = Mutex.new
        @wait_mutex = Mutex.new
        @condition = ConditionVariable.new
        @processes = {}
        @frames_received = @frames_stale = @sequence_gaps = @malformed_frames = 0
        @decoder_truncations = @process_limit_drops = @stall_sequence = 0
        @internal_errors = 0
        @process_limit_reported = @stopping = false
        start_parent_session!
        activate!
      rescue StandardError => e
        startup_failure!(e)
      end

      def active? = state == :active
      def stopped? = state == :stopped

      def ingest(bytes, now_ns: @clock.monotonic_ns)
        return 0 unless active?

        result = @decoder.feed(bytes, max_frames: policy.max_frames_per_poll)
        events = []
        @mutex.synchronize do
          @malformed_frames += result.malformed_frames
          @decoder_truncations += 1 if result.truncated?
          result.frames.each { |frame| accept_frame(frame, now_ns, events) }
        end
        emit_events(events)
        result.frames.size
      rescue StandardError => e
        monitor_failure!(e)
        0
      end

      def poll(now_ns: @clock.monotonic_ns)
        return 0 unless active?

        events = []
        @mutex.synchronize do
          @processes.each do |identity, process|
            next if process.stalled

            age_ns = now_ns - process.observed_monotonic_ns
            next unless age_ns >= 0 && policy.stalled?(age_ns: age_ns)

            @stall_sequence += 1
            @processes[identity] = ProcessState.new(**process.to_h, stalled: true)
            events << event(:process_progress_stall_started, now_ns,
                            process_measurements(process).merge(
                              stall_sequence: @stall_sequence,
                              silence_ns: age_ns,
                              process_count: @processes.size
                            ))
          end
        end
        emit_events(events)
        events.size
      rescue StandardError => e
        monitor_failure!(e)
        0
      end

      def stop
        return self if stopped?

        request_stop
        stop_thread
        drain_reader
        poll
        emit(:process_progress_monitor_completed, counter_measurements)
        close_reader
        recorder&.close(status: @internal_errors.positive? ? :degraded : :completed)
        @state = :stopped
        self
      rescue StandardError => e
        account_internal_error
        close_reader
        recorder&.close(status: :degraded) unless recorder&.closed?
        @state = :stopped
        raise e unless fail_open?

        self
      end

      private

      def validate_dependencies!(candidate_policy, candidate_settings, candidate_reader, candidate_clock,
                                 session_ids, pids, writers, random, threads)
        unless candidate_policy.is_a?(ProcessProgressPolicy) && candidate_policy.enabled?
          raise RuntimeContractError,
                'process progress monitor requires an enabled ProcessProgressPolicy'
        end
        unless candidate_settings.is_a?(Environment::Settings)
          raise RuntimeContractError,
                'settings must be a FiberAudit::Runtime::Environment::Settings'
        end
        unless candidate_reader.respond_to?(:read_nonblock) && candidate_reader.respond_to?(:close)
          raise RuntimeContractError, 'reader must respond to read_nonblock and close'
        end
        raise RuntimeContractError, 'clock must be a FiberAudit::Runtime::Clock' unless candidate_clock.is_a?(Clock)

        { 'session_id_source' => session_ids, 'pid_source' => pids, 'writer_factory' => writers,
          'random source' => random, 'thread_factory' => threads }.each do |name, dependency|
          raise RuntimeContractError, "#{name} must respond to call" unless dependency.respond_to?(:call)
        end
      end

      def start_parent_session!
        session_id = @session_id_source.call
        unless session_id.is_a?(String) && session_id.match?(Validation::UUID)
          raise RuntimeContractError,
                'session ID source must return a canonical lowercase UUID'
        end

        @output_path = File.join(settings.output_directory,
                                 "fiber-audit-parent-#{settings.launch_id}-#{@owner_pid}-#{session_id}.jsonl").freeze
        session = Session.new(id: session_id, started_at: @clock.wall_time,
                              started_monotonic_ns: @clock.monotonic_ns,
                              schema_version: '1.1', process_role: :parent_monitor,
                              policy: settings.policy)
        writer = @writer_factory.call(path: output_path, max_record_bytes: settings.policy.max_record_bytes)
        @recorder = Recorder.start(session: session, writer: writer, clock: @clock, random: @random)
      rescue StandardError
        writer&.close
        raise
      end

      def activate!
        raise RuntimeSafetyError, 'parent process-progress recorder is inactive' unless recorder.active?

        @state = :active
        emit(:process_progress_monitor_active, policy_measurements)
        @thread = @thread_factory.call { run }
        raise RuntimeContractError, 'thread_factory must return a Thread' unless @thread.is_a?(Thread)

        @thread.report_on_exception = false
        @thread.abort_on_exception = !fail_open?
        @thread.name = 'fiber-audit-process-progress-monitor' if @thread.respond_to?(:name=)
      end

      def run
        until stopping?
          # Deliberately bypass Fiber scheduler hooks from this dedicated native thread.
          ready = IO.select([reader], nil, nil, READ_WAIT_SECONDS) # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler
          drain_reader if ready
          poll
        end
      rescue IOError, Errno::EBADF
        nil if stopping?
      rescue StandardError => e
        monitor_failure!(e)
        raise e unless fail_open?
      end

      def drain_reader
        return unless active?

        maximum = [policy.max_buffer_bytes,
                   ProcessProgressProtocol::FRAME_BYTES * policy.max_frames_per_poll].min
        bytes = reader.read_nonblock(maximum, exception: false)
        case bytes
        when String then ingest(bytes)
        when nil then request_stop
        when :wait_readable then 0
        else raise RuntimeSafetyError, 'process progress reader returned an invalid result'
        end
      rescue EOFError
        request_stop
        0
      rescue IOError, Errno::EBADF
        raise unless stopping?

        0
      end

      # Frame admission atomically updates bounded process state and transition evidence.
      # rubocop:disable Metrics/AbcSize
      def accept_frame(frame, now_ns, events)
        identity = [frame.pid, frame.generation].freeze
        previous = @processes[identity]
        if previous.nil?
          unless @processes.size < policy.max_processes
            @process_limit_drops += 1
            unless @process_limit_reported
              @process_limit_reported = true
              events << event(:process_progress_monitor_truncated, now_ns,
                              process_limit_exhausted: true, process_count: @processes.size,
                              max_processes: policy.max_processes)
            end
            return
          end
          current = ProcessState.new(pid: frame.pid, generation: frame.generation,
                                     sequence: frame.sequence, child_monotonic_ns: frame.monotonic_ns,
                                     observed_monotonic_ns: now_ns, stalled: false)
          @processes[identity] = current
          @frames_received += 1
          events << event(:process_progress_process_observed, now_ns,
                          process_measurements(current).merge(process_count: @processes.size))
          return
        end

        if frame.sequence <= previous.sequence
          @frames_stale += 1
          return
        end
        gap = frame.sequence - previous.sequence - 1
        @sequence_gaps += gap
        current = ProcessState.new(pid: frame.pid, generation: frame.generation,
                                   sequence: frame.sequence, child_monotonic_ns: frame.monotonic_ns,
                                   observed_monotonic_ns: now_ns, stalled: false)
        @processes[identity] = current
        @frames_received += 1
        return unless previous.stalled

        events << event(:process_progress_stall_completed, now_ns,
                        process_measurements(current).merge(
                          silence_ns: now_ns - previous.observed_monotonic_ns,
                          sequence_gap: gap
                        ))
      end
      # rubocop:enable Metrics/AbcSize

      def event(kind, monotonic_ns, measurements)
        Event.new(kind: kind, source: SOURCE, occurred_at: @clock.wall_time,
                  monotonic_ns: monotonic_ns, measurements: measurements)
      end

      def emit(kind, measurements) = emit_events([event(kind, @clock.monotonic_ns, measurements)])
      def emit_events(events) = events.each { |entry| recorder.record_control { entry } }

      def process_measurements(process)
        { process_pid: process.pid, process_generation: process.generation,
          progress_sequence: process.sequence, child_monotonic_ns: process.child_monotonic_ns }
      end

      def policy_measurements
        { heartbeat_interval_ns: policy.heartbeat_interval_ns, stall_threshold_ns: policy.stall_threshold_ns,
          max_processes: policy.max_processes, max_frames_per_poll: policy.max_frames_per_poll,
          max_buffer_bytes: policy.max_buffer_bytes }
      end

      def counter_measurements
        @mutex.synchronize do
          policy_measurements.merge(
            process_count: @processes.size, frames_received: @frames_received,
            frames_stale: @frames_stale, sequence_gaps: @sequence_gaps,
            malformed_frames: @malformed_frames, decoder_truncations: @decoder_truncations,
            process_limit_drops: @process_limit_drops, monitor_internal_errors: @internal_errors
          )
        end
      end

      def request_stop
        @wait_mutex.synchronize do
          @stopping = true
          @condition.broadcast
        end
      end

      def stopping? = @wait_mutex.synchronize { @stopping }

      def stop_thread
        thread = @thread
        return unless thread && thread != Thread.current
        return if thread.join(STOP_TIMEOUT_SECONDS)

        account_internal_error
        thread.kill
        thread.join
      ensure
        @thread = nil
      end

      def close_reader
        reader&.close unless reader&.closed?
      rescue StandardError
        account_internal_error
      end

      def monitor_failure!(error)
        account_internal_error
        @state = :unsupported
        emit(:process_progress_monitor_unsupported, counter_measurements) if recorder&.active?
        request_stop
        raise error unless fail_open?
      rescue StandardError
        raise error unless fail_open?
      end

      def startup_failure!(error)
        @state = :unsupported
        account_internal_error if defined?(@recorder) && recorder
        close_reader if defined?(@reader) && reader
        recorder&.close(status: :degraded) unless recorder&.closed?
        raise error unless defined?(@settings) && settings.policy.fail_open?
      end

      def account_internal_error
        @internal_errors = @internal_errors.to_i + 1
        recorder&.internal_error!
      rescue StandardError
        nil
      end

      def fail_open? = settings.policy.fail_open?

      def current_pid
        value = @pid_source.call
        return value if value.is_a?(Integer) && value.positive?

        raise RuntimeContractError, 'pid source must return a positive Integer'
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
