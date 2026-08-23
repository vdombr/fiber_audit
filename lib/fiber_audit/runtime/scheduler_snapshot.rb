# frozen_string_literal: true

module FiberAudit
  module Runtime
    # Immutable scheduler snapshot/context fields captured at operation start.
    # All fields are Boolean or nil only, as per JSONL 1.0 schema requirements.
    SchedulerSnapshot = Data.define(
      :scheduler_present,
      :fiber_blocking,
      :scheduler_io_select_supported,
      :scheduler_process_wait_supported,
      :scheduler_address_resolve_supported
    ) do
      def initialize(
        scheduler_present:,
        fiber_blocking:,
        scheduler_io_select_supported: nil,
        scheduler_process_wait_supported: nil,
        scheduler_address_resolve_supported: nil
      )
        super(
          scheduler_present: normalize_optional_boolean(scheduler_present, 'scheduler_present'),
          fiber_blocking: normalize_optional_boolean(fiber_blocking, 'fiber_blocking'),
          scheduler_io_select_supported: normalize_optional_boolean(
            scheduler_io_select_supported,
            'scheduler_io_select_supported'
          ),
          scheduler_process_wait_supported: normalize_optional_boolean(
            scheduler_process_wait_supported,
            'scheduler_process_wait_supported'
          ),
          scheduler_address_resolve_supported: normalize_optional_boolean(
            scheduler_address_resolve_supported,
            'scheduler_address_resolve_supported'
          )
        )
      end

      def to_measurements
        {
          scheduler_present: scheduler_present,
          fiber_blocking: fiber_blocking,
          scheduler_io_select_supported: scheduler_io_select_supported,
          scheduler_process_wait_supported: scheduler_process_wait_supported,
          scheduler_address_resolve_supported: scheduler_address_resolve_supported
        }.freeze
      end

      private

      def normalize_optional_boolean(value, field)
        return value if value.nil?
        raise RuntimeContractError, "#{field} must be a Boolean or nil" unless [true, false].include?(value)

        value
      end
    end

    # Captures immutable scheduler snapshot at the current point in time.
    # This is called at operation start to provide immutable context.
    module SchedulerSnapshotCapture
      module_function

      def capture
        scheduler = Fiber.scheduler
        scheduler_present = !scheduler.nil?

        current_fiber = Fiber.current
        fiber_blocking = current_fiber.respond_to?(:blocking?) ? current_fiber.blocking? : nil

        # Query scheduler capabilities if present
        io_select_supported = nil
        process_wait_supported = nil
        address_resolve_supported = nil

        if scheduler_present
          io_select_supported = scheduler.respond_to?(:io_select)
          process_wait_supported = scheduler.respond_to?(:process_wait)
          address_resolve_supported = scheduler.respond_to?(:address_resolve)
        end

        SchedulerSnapshot.new(
          scheduler_present: scheduler_present,
          fiber_blocking: fiber_blocking,
          scheduler_io_select_supported: io_select_supported,
          scheduler_process_wait_supported: process_wait_supported,
          scheduler_address_resolve_supported: address_resolve_supported
        )
      rescue StandardError
        # Fail open without inventing scheduler or Fiber state.
        SchedulerSnapshot.new(scheduler_present: nil, fiber_blocking: nil)
      end
    end
  end
end
