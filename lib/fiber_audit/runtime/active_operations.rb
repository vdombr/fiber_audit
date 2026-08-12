# frozen_string_literal: true

require_relative 'event'
require_relative 'location'
require_relative 'scheduler_snapshot'
require_relative 'validation'

module FiberAudit
  module Runtime
    # Bounded process-local registry shared by the watchdog and future probes.
    class ActiveOperations
      MAX_ENTRIES = 10_000
      MAX_SNAPSHOT = 100

      Handle = Data.define(:pid, :thread_id, :fiber_id, :sequence)
      Entry = Data.define(
        :thread_id,
        :fiber_id,
        :sequence,
        :operation,
        :location,
        :execution_context,
        :started_monotonic_ns,
        :scheduler_snapshot
      )

      def initialize(pid_source: Process.method(:pid), capacity: MAX_ENTRIES, snapshot_limit: MAX_SNAPSHOT)
        validate_source!(pid_source)
        validate_limit!(capacity, 'capacity', MAX_ENTRIES)
        validate_limit!(snapshot_limit, 'snapshot_limit', MAX_SNAPSHOT)
        @pid_source = pid_source
        @capacity = capacity
        @snapshot_limit = snapshot_limit
        reset_for_process!(current_pid)
      end

      def register(
        operation:,
        monotonic_ns:,
        location: nil,
        execution_context: :unknown,
        thread: Thread.current,
        fiber: Fiber.current,
        scheduler_snapshot: nil
      )
        ensure_current_process!
        values = normalize_entry(
          operation: operation,
          location: location,
          execution_context: execution_context,
          monotonic_ns: monotonic_ns,
          thread: thread,
          fiber: fiber,
          scheduler_snapshot: scheduler_snapshot
        )

        @mutex.synchronize do
          return if @entries.size >= @capacity

          @sequence += 1
          entry = Entry.new(sequence: @sequence, **values)
          handle = Handle.new(
            pid: @owner_pid,
            thread_id: entry.thread_id,
            fiber_id: entry.fiber_id,
            sequence: entry.sequence
          )
          @entries[handle] = entry
          handle
        end
      end

      def finish(handle)
        ensure_current_process!
        return unless handle.is_a?(Handle) && handle.pid == @owner_pid

        @mutex.synchronize { @entries.delete(handle) }
      end

      def snapshot(thread_id: nil)
        ensure_current_process!
        normalized_thread_id = Validation.integer(thread_id, 'thread_id', allow_nil: true)
        @mutex.synchronize do
          entries = @entries.values
          entries = entries.select { |entry| entry.thread_id == normalized_thread_id } if normalized_thread_id
          entries.sort_by(&:sequence).first(@snapshot_limit).freeze
        end
      end

      def size
        ensure_current_process!
        @mutex.synchronize { @entries.size }
      end

      private

      def normalize_entry(operation:, location:, execution_context:, monotonic_ns:, thread:, fiber:, scheduler_snapshot: nil)
        canonical_operation = Validation.operation(operation)
        unless location.nil? || location.is_a?(Location)
          raise RuntimeContractError, 'location must be a FiberAudit::Runtime::Location or nil'
        end

        normalized_context = execution_context.to_sym if execution_context.is_a?(String) || execution_context.is_a?(Symbol)
        raise RuntimeContractError, 'execution_context is invalid' unless Context::ALL.include?(normalized_context)

        unless thread.respond_to?(:object_id) && fiber.respond_to?(:object_id)
          raise RuntimeContractError, 'thread and fiber identities are invalid'
        end

        normalized_snapshot = normalize_scheduler_snapshot(scheduler_snapshot)

        {
          thread_id: Validation.integer(thread.object_id, 'thread_id'),
          fiber_id: Validation.integer(fiber.object_id, 'fiber_id'),
          operation: canonical_operation,
          location: location,
          execution_context: normalized_context,
          started_monotonic_ns: Validation.integer(monotonic_ns, 'monotonic_ns'),
          scheduler_snapshot: normalized_snapshot
        }
      end

      def normalize_scheduler_snapshot(value)
        return value if value.nil?
        return value if value.is_a?(SchedulerSnapshot)

        raise RuntimeContractError, 'scheduler_snapshot must be a FiberAudit::Runtime::SchedulerSnapshot or nil'
      end

      def ensure_current_process!
        pid = current_pid
        reset_for_process!(pid) unless pid == @owner_pid
      end

      def reset_for_process!(pid)
        @owner_pid = pid
        @mutex = Mutex.new
        @entries = {}
        @sequence = 0
      end

      def current_pid
        value = @pid_source.call
        return value if value.is_a?(Integer) && value.positive?

        raise RuntimeContractError, 'pid source must return a positive Integer'
      end

      def validate_source!(source)
        raise RuntimeContractError, 'pid_source must respond to call' unless source.respond_to?(:call)
      end

      def validate_limit!(value, name, maximum)
        return if value.is_a?(Integer) && value.between?(1, maximum)

        raise RuntimeContractError, "#{name} must be an Integer in 1..#{maximum}"
      end
    end
  end
end
