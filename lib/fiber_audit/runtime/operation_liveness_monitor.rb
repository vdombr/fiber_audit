# frozen_string_literal: true

require_relative 'active_operations'
require_relative 'clock'
require_relative 'event'
require_relative 'operation_liveness_policy'
require_relative 'recorder'
require_relative 'scheduler_evidence_classifier'

module FiberAudit
  module Runtime
    class OperationLivenessMonitor
      SOURCE = :operation_liveness_monitor
      STOP_TIMEOUT_SECONDS = 1
      MAX_START_EVENTS_PER_POLL = 10
      Tracked = Data.define(:long_active_sequence, :entry)

      attr_reader :policy, :recorder, :active_operations, :state

      def initialize(policy:, recorder:, active_operations:, clock: Clock.new,
                     thread_factory: ->(&block) { Thread.new(&block) })
        validate_dependencies!(policy, recorder, active_operations, clock, thread_factory)
        @policy = policy
        @recorder = recorder
        @active_operations = active_operations
        @clock = clock
        @thread_factory = thread_factory
        @poll_mutex = Mutex.new
        @wait_mutex = Mutex.new
        @condition = ConditionVariable.new
        @tracked = {}
        @long_active_sequence = 0
        @monitor_thread = nil
        @state = policy.enabled? ? :starting : :disabled
        @stopping = false
        @stopped = false
        activate!
      end

      def enabled? = policy.enabled?
      def fail_open? = recorder.session.policy.fail_open?

      def poll(now_ns: nil)
        return state unless enabled? && state == :active

        observed_now = now_ns.nil? ? @clock.monotonic_ns : Validation.integer(now_ns, 'operation liveness poll time')
        @poll_mutex.synchronize { poll_operations(observed_now) }
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
        stop_monitor_thread
        now_ns = safe_monotonic_ns
        @poll_mutex.synchronize { close_tracked(now_ns, operation_finished: false) }
        @stopped = true
        self
      rescue StandardError => e
        handle_failure(e)
        @stopped = true
        raise e unless fail_open?

        self
      end

      private

      def activate!
        if policy.enabled?
          start_monitor_thread
          @state = :active
          emit_state(:operation_liveness_active)
        else
          emit_state(:operation_liveness_disabled)
        end
      rescue StandardError => e
        handle_failure(e)
        raise e unless fail_open?
      end

      def validate_dependencies!(candidate_policy, candidate_recorder, operations, candidate_clock, threads)
        unless candidate_policy.is_a?(OperationLivenessPolicy)
          raise RuntimeContractError, 'policy must be a FiberAudit::Runtime::OperationLivenessPolicy'
        end
        unless candidate_recorder.is_a?(Recorder)
          raise RuntimeContractError,
                'recorder must be a FiberAudit::Runtime::Recorder'
        end
        unless operations.is_a?(ActiveOperations)
          raise RuntimeContractError, 'active_operations must be FiberAudit::Runtime::ActiveOperations'
        end
        raise RuntimeContractError, 'clock must be a FiberAudit::Runtime::Clock' unless candidate_clock.is_a?(Clock)
        raise RuntimeContractError, 'thread_factory must respond to call' unless threads.respond_to?(:call)
      end

      def poll_operations(now_ns)
        snapshot = active_operations.snapshot_with_metadata
        current = snapshot.entries.to_h { |entry| [entry.sequence, entry] }
        complete_absent(current, now_ns)
        start_overdue(snapshot, current, now_ns)
      end

      def complete_absent(current, now_ns)
        @tracked.keys.reject { |sequence| current.key?(sequence) }.each do |sequence|
          emit_completion(@tracked.delete(sequence), now_ns, operation_finished: true)
        end
      end

      def start_overdue(snapshot, current, now_ns)
        overdue = current.values.reject do |entry|
          @tracked.key?(entry.sequence) || !long_active?(entry, now_ns)
        end
        bounded = overdue.first(MAX_START_EVENTS_PER_POLL)
        batch_truncated = overdue.size > bounded.size
        bounded.each do |entry|
          @long_active_sequence += 1
          tracked = Tracked.new(long_active_sequence: @long_active_sequence, entry: entry)
          @tracked[entry.sequence] = tracked
          emit_start(tracked, now_ns, snapshot, batch_truncated, overdue.size)
        end
      end

      def long_active?(entry, now_ns)
        raise RuntimeSafetyError, 'operation liveness clock moved backwards' if now_ns < entry.started_monotonic_ns

        policy.long_active?(age_ns: now_ns - entry.started_monotonic_ns)
      end

      def classifier_measurements(entry)
        SchedulerEvidenceClassifier.measurements(
          operation: entry.operation,
          scheduler_snapshot: entry.scheduler_snapshot
        )
      end

      def emit_start(tracked, now_ns, snapshot, batch_truncated, candidate_count)
        entry = tracked.entry
        age_ns = now_ns - entry.started_monotonic_ns
        measurements = {
          long_active_sequence: tracked.long_active_sequence,
          operation_sequence: entry.sequence,
          operation_started_monotonic_ns: entry.started_monotonic_ns,
          observed_age_ns: age_ns,
          long_active_threshold_ns: policy.long_active_threshold_ns,
          poll_interval_ns: policy.poll_interval_ns,
          active_operation_total_count: snapshot.total_count,
          active_operation_snapshot_truncated: snapshot.truncated?,
          long_active_batch_truncated: batch_truncated,
          long_active_candidate_count: candidate_count
        }
        measurements.merge!(entry.scheduler_snapshot.to_measurements) if entry.scheduler_snapshot
        measurements.merge!(classifier_measurements(entry))
        emit_event(kind: :operation_long_active_started, entry: entry, monotonic_ns: now_ns,
                   duration_ns: age_ns, measurements: measurements)
      end

      def emit_completion(tracked, now_ns, operation_finished:)
        entry = tracked.entry
        duration_ns = [now_ns - entry.started_monotonic_ns, 0].max
        measurements = {
          long_active_sequence: tracked.long_active_sequence,
          operation_sequence: entry.sequence,
          operation_started_monotonic_ns: entry.started_monotonic_ns,
          long_active_threshold_ns: policy.long_active_threshold_ns,
          operation_finished: operation_finished
        }
        measurements.merge!(entry.scheduler_snapshot.to_measurements) if entry.scheduler_snapshot
        measurements.merge!(classifier_measurements(entry))
        emit_event(kind: :operation_long_active_completed, entry: entry, monotonic_ns: now_ns,
                   duration_ns: duration_ns, measurements: measurements)
      end

      def close_tracked(now_ns, operation_finished:)
        tracked = @tracked.values
        @tracked.clear
        tracked.each { |entry| emit_completion(entry, now_ns, operation_finished: operation_finished) }
      end

      def emit_state(kind)
        emit_event(kind: kind, entry: nil, monotonic_ns: @clock.monotonic_ns,
                   measurements: { poll_interval_ns: policy.poll_interval_ns,
                                   long_active_threshold_ns: policy.long_active_threshold_ns })
      end

      def emit_event(kind:, entry:, monotonic_ns:, duration_ns: nil, measurements: {})
        recorder.record_control do
          Event.new(
            kind: kind,
            source: SOURCE,
            occurred_at: @clock.wall_time,
            monotonic_ns: monotonic_ns,
            duration_ns: duration_ns,
            operation: entry&.operation,
            location: entry&.location,
            execution_context: entry&.execution_context || :unknown,
            thread_id: entry&.thread_id,
            fiber_id: entry&.fiber_id,
            measurements: measurements
          )
        end
      end

      def start_monitor_thread
        thread = @thread_factory.call { monitor_loop }
        raise RuntimeContractError, 'thread_factory must return a Thread' unless thread.is_a?(Thread)

        @monitor_thread = thread
        thread.report_on_exception = false
        thread.abort_on_exception = !fail_open?
        thread.name = 'fiber-audit-operation-liveness' if thread.respond_to?(:name=)
      end

      def monitor_loop
        loop do
          should_stop = @wait_mutex.synchronize do
            @condition.wait(@wait_mutex, policy.poll_interval_ms.fdiv(1_000)) unless @stopping
            @stopping
          end
          break if should_stop

          poll
        end
      rescue StandardError => e
        handle_failure(e)
        raise e unless fail_open?
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
        first_failure = @state != :unsupported
        @state = :unsupported
        @wait_mutex&.synchronize do
          @stopping = true
          @condition&.broadcast
        end
        account_internal_error
        begin
          emit_state(:operation_liveness_unsupported) if first_failure
        rescue StandardError
          nil
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
  end
end
