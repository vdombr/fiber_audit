# frozen_string_literal: true

require_relative 'active_operations'
require_relative 'clock'
require_relative 'event'
require_relative 'heartbeat'
require_relative 'recorder'
require_relative 'redactor'
require_relative 'watchdog_policy'

module FiberAudit
  module Runtime
    # Monitors scheduler-owned heartbeat fibers from one dedicated process thread.
    # rubocop:disable Metrics/ClassLength
    class Watchdog
      SOURCE = :scheduler_watchdog
      STOP_TIMEOUT_SECONDS = 1
      MAX_OVERLAP_EVENTS = 10

      Stall = Data.define(:sequence, :progress_sequence, :began_monotonic_ns)
      Channel = Struct.new(:thread, :heartbeat, :active, :unsupported, :stall, keyword_init: true)

      attr_reader :policy, :recorder, :active_operations

      def initialize(
        policy:,
        recorder:,
        redactor:,
        active_operations:,
        clock: Clock.new,
        thread_factory: ->(&block) { Thread.new(&block) }
      )
        validate_dependencies!(policy, recorder, redactor, active_operations, clock, thread_factory)
        @policy = policy
        @recorder = recorder
        @redactor = redactor
        @active_operations = active_operations
        @clock = clock
        @thread_factory = thread_factory
        @mutex = Mutex.new
        @wait_mutex = Mutex.new
        @condition = ConditionVariable.new
        @channels = {}.compare_by_identity
        @stall_sequence = 0
        @unsupported_seen = false
        @monitor_thread = nil
        @stopping = false
        @stopped = false
        emit_state(policy.enabled? ? :watchdog_absent : :watchdog_disabled)
      end

      def enabled?
        policy.enabled?
      end

      def fail_open?
        recorder.session.policy.fail_open?
      end

      def state
        return :disabled unless enabled?

        @mutex.synchronize do
          return :active if @channels.values.any?(&:active)
          return :unsupported if @unsupported_seen || @channels.values.any?(&:unsupported)

          :absent
        end
      end

      def scheduler_installed(
        thread: Thread.current,
        schedule: Fiber.method(:schedule),
        sleeper: Kernel.method(:sleep)
      )
        return self unless enabled?
        raise RuntimeContractError, 'scheduler thread must be a Thread' unless thread.is_a?(Thread)

        heartbeat = Heartbeat.new(
          clock: @clock,
          interval_ns: policy.heartbeat_interval_ns,
          owner_thread: thread,
          on_tick: method(:heartbeat_ticked),
          on_error: method(:heartbeat_failed)
        )
        previous = @mutex.synchronize do
          prior = @channels[thread]
          @channels[thread] = Channel.new(
            thread: thread,
            heartbeat: heartbeat,
            active: false,
            unsupported: false,
            stall: nil
          )
          prior
        end
        previous&.heartbeat&.request_stop
        heartbeat.start(schedule: schedule, sleeper: sleeper)
        self
      rescue StandardError => e
        channel_failure(thread, e)
        raise e unless fail_open?

        self
      end

      def scheduler_unsupported(thread: Thread.current)
        return self unless enabled?

        channel_failure(thread, nil)
        self
      end

      def scheduler_closing(thread: Thread.current)
        return self unless enabled?

        now_ns = safe_monotonic_ns
        @mutex.synchronize do
          channel = @channels.delete(thread)
          next unless channel

          channel.heartbeat.request_stop
          complete_stall(channel, now_ns: now_ns, resumed: false) if channel.stall
          unless channel.active || channel.unsupported
            @unsupported_seen = true
            emit_state(:watchdog_unsupported, thread: thread)
          end
        end
        wake_monitor
        self
      rescue StandardError => e
        handle_failure(e)
        raise e unless fail_open?

        self
      end

      def poll(now_ns: nil)
        return state unless enabled?

        observed_now = now_ns.nil? ? @clock.monotonic_ns : Validation.integer(now_ns, 'watchdog poll time')
        @mutex.synchronize do
          @channels.each_value { |channel| poll_channel(channel, observed_now) if channel.active }
        end
        state
      rescue StandardError => e
        handle_failure(e)
        raise e unless fail_open?

        :unsupported
      end

      def stop
        return self if @stopped

        @wait_mutex.synchronize do
          @stopping = true
          @condition.broadcast
        end
        now_ns = safe_monotonic_ns
        @mutex.synchronize do
          @channels.each_value do |channel|
            channel.heartbeat.request_stop
            complete_stall(channel, now_ns: now_ns, resumed: false) if channel.stall
            if !channel.active && !channel.unsupported
              @unsupported_seen = true
              emit_state(:watchdog_unsupported, thread: channel.thread)
            end
          end
          @channels.clear
        end
        stop_monitor_thread
        @stopped = true
        self
      rescue StandardError => e
        handle_failure(e)
        @stopped = true
        raise e unless fail_open?

        self
      end

      private

      def validate_dependencies!(watchdog_policy, candidate_recorder, redactor, operations, clock, threads)
        unless watchdog_policy.is_a?(WatchdogPolicy)
          raise RuntimeContractError, 'policy must be a FiberAudit::Runtime::WatchdogPolicy'
        end
        unless candidate_recorder.is_a?(Recorder)
          raise RuntimeContractError, 'recorder must be a FiberAudit::Runtime::Recorder'
        end
        raise RuntimeContractError, 'redactor must be a FiberAudit::Runtime::Redactor' unless redactor.is_a?(Redactor)
        unless operations.is_a?(ActiveOperations)
          raise RuntimeContractError, 'active_operations must be FiberAudit::Runtime::ActiveOperations'
        end
        raise RuntimeContractError, 'clock must be a FiberAudit::Runtime::Clock' unless clock.is_a?(Clock)
        raise RuntimeContractError, 'thread_factory must respond to call' unless threads.respond_to?(:call)
      end

      def heartbeat_ticked(heartbeat)
        activate = false
        @mutex.synchronize do
          channel = @channels[heartbeat.owner_thread]
          return unless channel&.heartbeat.equal?(heartbeat)

          unless channel.active
            channel.active = true
            activate = true
          end
        end
        if activate
          snapshot = heartbeat.snapshot
          emit_state(
            :watchdog_active,
            thread: heartbeat.owner_thread,
            fiber_id: snapshot.fiber_id,
            measurements: policy_measurements
          )
          start_monitor_thread
        end
        wake_monitor
      rescue StandardError => e
        heartbeat_failed(heartbeat, e)
      end

      def heartbeat_failed(heartbeat, error)
        channel_failure(heartbeat.owner_thread, error)
        raise error unless fail_open?
      end

      def channel_failure(thread, error)
        already_unsupported = false
        @mutex.synchronize do
          entry = @channels[thread]
          if entry
            already_unsupported = entry.unsupported
            entry.heartbeat.request_stop
            entry.unsupported = true
            entry.active = false
          else
            already_unsupported = @unsupported_seen
          end
          @unsupported_seen = true
        end
        account_internal_error if error
        emit_state(:watchdog_unsupported, thread: thread) unless already_unsupported
      end

      def poll_channel(channel, now_ns)
        snapshot = channel.heartbeat.snapshot
        return unless snapshot.started && snapshot.last_progress_ns
        raise RuntimeSafetyError, 'watchdog monotonic clock moved backwards' if now_ns < snapshot.last_progress_ns

        if channel.stall
          complete_stall(channel, now_ns: now_ns, resumed: true) if snapshot.sequence > channel.stall.progress_sequence
          return
        end

        age_ns = now_ns - snapshot.last_progress_ns
        start_stall(channel, snapshot, age_ns, now_ns) if policy.stalled?(age_ns: age_ns)
      end

      def start_stall(channel, snapshot, age_ns, now_ns)
        @stall_sequence += 1
        channel.stall = Stall.new(
          sequence: @stall_sequence,
          progress_sequence: snapshot.sequence,
          began_monotonic_ns: snapshot.last_progress_ns
        )
        operations = active_operations.snapshot(thread_id: snapshot.thread_id)
        frames = safe_frames(channel.thread)
        measurements = {
          stall_sequence: @stall_sequence,
          progress_sequence: snapshot.sequence,
          observed_age_ns: age_ns,
          stall_threshold_ns: policy.stall_threshold_ns,
          heartbeat_interval_ns: policy.heartbeat_interval_ns,
          frame_count: frames.size,
          active_operation_count: operations.size,
          active_operation_first_sequence: operations.first&.sequence,
          active_operation_last_sequence: operations.last&.sequence
        }
        emit_event(
          kind: :scheduler_stall_started,
          monotonic_ns: now_ns,
          thread_id: snapshot.thread_id,
          fiber_id: snapshot.fiber_id,
          measurements: measurements
        )
        frames.each_with_index do |location, index|
          emit_event(
            kind: :scheduler_stall_frame,
            monotonic_ns: now_ns,
            location: location,
            thread_id: snapshot.thread_id,
            fiber_id: snapshot.fiber_id,
            measurements: { stall_sequence: @stall_sequence, frame_index: index }
          )
        end
        emit_stall_operation_overlap_events(operations, now_ns, snapshot)
      end

      def emit_stall_operation_overlap_events(operations, now_ns, _snapshot)
        return if operations.empty?

        truncated = operations.size > MAX_OVERLAP_EVENTS
        bounded_operations = operations.first(MAX_OVERLAP_EVENTS)

        bounded_operations.each do |entry|
          overlap_measurements = build_overlap_measurements(entry, truncated, operations.size)
          emit_event(
            kind: :scheduler_stall_operation_overlap,
            monotonic_ns: now_ns,
            operation: entry.operation,
            location: entry.location,
            execution_context: entry.execution_context,
            thread_id: entry.thread_id,
            fiber_id: entry.fiber_id,
            measurements: overlap_measurements
          )
        end
      rescue StandardError => e
        account_internal_error unless recorder.disabled?
        raise e unless fail_open?
      end

      def build_overlap_measurements(entry, truncated, total_count)
        measurements = {
          stall_sequence: @stall_sequence,
          operation_sequence: entry.sequence,
          operation_started_monotonic_ns: entry.started_monotonic_ns,
          overlap_truncated: truncated,
          overlap_total_count: total_count
        }

        measurements.merge!(entry.scheduler_snapshot.to_measurements) if entry.scheduler_snapshot

        measurements
      end

      def complete_stall(channel, now_ns:, resumed:)
        stall = channel.stall
        return unless stall

        snapshot = channel.heartbeat.snapshot
        duration = [now_ns - stall.began_monotonic_ns, 0].max
        emit_event(
          kind: :scheduler_stall_completed,
          monotonic_ns: now_ns,
          duration_ns: duration,
          thread_id: snapshot.thread_id,
          fiber_id: snapshot.fiber_id,
          measurements: {
            stall_sequence: stall.sequence,
            progress_sequence: snapshot.sequence,
            resumed: resumed
          }
        )
        channel.stall = nil
      end

      def safe_frames(thread)
        return [] if policy.max_frames.zero?

        frames = thread.backtrace_locations(0, policy.max_frames) || []
        frames.first(policy.max_frames).filter_map do |frame|
          location = safe_frame_location(frame)
          location unless location.nil? || Location::SENTINELS.include?(location.path)
        rescue StandardError
          nil
        end.freeze
      rescue StandardError => e
        account_internal_error
        raise e unless fail_open?

        [].freeze
      end

      def safe_frame_location(frame)
        path = frame.absolute_path
        unless path
          relative = frame.path
          return unless relative.is_a?(String) && !relative.start_with?('-', '<')

          path = File.join(@redactor.root, relative)
        end
        @redactor.location(path: path, line: frame.lineno, column: nil)
      end

      def emit_state(kind, thread: nil, fiber_id: nil, measurements: {})
        state_measurements = measurements.empty? ? policy_measurements : measurements
        emit_event(
          kind: kind,
          monotonic_ns: @clock.monotonic_ns,
          thread_id: thread&.object_id,
          fiber_id: fiber_id,
          measurements: state_measurements
        )
      end

      def emit_event(kind:, monotonic_ns:, duration_ns: nil, location: nil, thread_id: nil, fiber_id: nil, operation: nil,
                     execution_context: :unknown, measurements: {})
        recorder.record_control do
          Event.new(
            kind: kind,
            source: SOURCE,
            occurred_at: @clock.wall_time,
            monotonic_ns: monotonic_ns,
            duration_ns: duration_ns,
            operation: operation,
            location: location,
            execution_context: execution_context,
            thread_id: thread_id,
            fiber_id: fiber_id,
            measurements: measurements
          )
        end
      rescue StandardError => e
        account_internal_error unless recorder.disabled?
        raise e unless fail_open?

        :internal_error
      end

      def policy_measurements
        {
          heartbeat_interval_ns: policy.heartbeat_interval_ns,
          stall_threshold_ns: policy.stall_threshold_ns,
          max_frames: policy.max_frames
        }
      end

      def start_monitor_thread
        @wait_mutex.synchronize do
          return if @monitor_thread || @stopping

          @monitor_thread = @thread_factory.call { monitor_loop }
          raise RuntimeContractError, 'thread_factory must return a Thread' unless @monitor_thread.is_a?(Thread)

          @monitor_thread.report_on_exception = false
          @monitor_thread.abort_on_exception = !fail_open?
          @monitor_thread.name = 'fiber-audit-watchdog' if @monitor_thread.respond_to?(:name=)
        end
      end

      def monitor_loop
        loop do
          should_stop = @wait_mutex.synchronize do
            @condition.wait(@wait_mutex, policy.heartbeat_interval_ms.fdiv(1_000)) unless @stopping
            @stopping
          end
          break if should_stop

          poll
        end
      rescue StandardError => e
        handle_failure(e)
        raise e unless fail_open?
      end

      def wake_monitor
        @wait_mutex.synchronize { @condition.broadcast }
      end

      def stop_monitor_thread
        thread = @monitor_thread
        return unless thread && thread != Thread.current

        return if thread.join(STOP_TIMEOUT_SECONDS)

        account_internal_error
        thread.kill
        thread.join
      ensure
        @monitor_thread = nil
      end

      def handle_failure(error)
        first_failure = false
        failed_thread = nil
        unless @mutex.owned?
          @mutex.synchronize do
            first_failure = !@unsupported_seen
            @unsupported_seen = true
            @channels.each_value do |channel|
              failed_thread ||= channel.thread
              channel.heartbeat.request_stop
              channel.active = false
              channel.unsupported = true
            end
          end
        end
        if first_failure
          account_internal_error
          begin
            emit_state(:watchdog_unsupported, thread: failed_thread)
          rescue StandardError
            nil
          end
        end
        error
      end

      def account_internal_error
        recorder.internal_error!
      rescue StandardError
        nil
      end

      def safe_monotonic_ns
        @clock.monotonic_ns
      rescue StandardError => e
        account_internal_error
        raise e unless fail_open?

        recorder.session.started_monotonic_ns
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
