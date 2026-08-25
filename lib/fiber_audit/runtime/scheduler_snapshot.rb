# frozen_string_literal: true

module FiberAudit
  module Runtime
    SchedulerSnapshot = Data.define(
      :scheduler_present,
      :current_scheduler_present,
      :scheduler_snapshot_consistent,
      :fiber_blocking,
      :scheduler_block_supported,
      :scheduler_kernel_sleep_supported,
      :scheduler_io_wait_supported,
      :scheduler_io_select_supported,
      :scheduler_process_wait_supported,
      :scheduler_address_resolve_supported
    ) do
      def initialize(
        scheduler_present:,
        fiber_blocking:, current_scheduler_present: nil,
        scheduler_snapshot_consistent: nil,
        scheduler_block_supported: nil,
        scheduler_kernel_sleep_supported: nil,
        scheduler_io_wait_supported: nil,
        scheduler_io_select_supported: nil,
        scheduler_process_wait_supported: nil,
        scheduler_address_resolve_supported: nil
      )
        values = {
          scheduler_present: scheduler_present,
          current_scheduler_present: current_scheduler_present,
          scheduler_snapshot_consistent: scheduler_snapshot_consistent,
          fiber_blocking: fiber_blocking,
          scheduler_block_supported: scheduler_block_supported,
          scheduler_kernel_sleep_supported: scheduler_kernel_sleep_supported,
          scheduler_io_wait_supported: scheduler_io_wait_supported,
          scheduler_io_select_supported: scheduler_io_select_supported,
          scheduler_process_wait_supported: scheduler_process_wait_supported,
          scheduler_address_resolve_supported: scheduler_address_resolve_supported
        }
        super(**values.to_h { |name, value| [name, normalize_optional_boolean(value, name)] })
      end

      def to_measurements = to_h.freeze

      private

      def normalize_optional_boolean(value, field)
        return value if value.nil? || [true, false].include?(value)

        raise RuntimeContractError, "#{field} must be a Boolean or nil"
      end
    end

    module SchedulerSnapshotCapture
      CORE_HOOKS = %i[block kernel_sleep io_wait].freeze
      OPTIONAL_HOOKS = %i[io_select process_wait address_resolve].freeze

      module_function

      def capture
        scheduler = Fiber.scheduler
        current_scheduler_supported = Fiber.respond_to?(:current_scheduler)
        current_scheduler = Fiber.current_scheduler if current_scheduler_supported
        current_fiber = Fiber.current
        fiber_blocking = current_fiber.respond_to?(:blocking?) ? current_fiber.blocking? : nil

        scheduler_present = !scheduler.nil?
        current_scheduler_present = current_scheduler_supported ? !current_scheduler.nil? : nil
        capabilities = capability_measurements(scheduler)

        SchedulerSnapshot.new(
          scheduler_present: scheduler_present,
          current_scheduler_present: current_scheduler_present,
          scheduler_snapshot_consistent: snapshot_consistent(
            scheduler: scheduler,
            current_scheduler: current_scheduler,
            current_scheduler_supported: current_scheduler_supported,
            fiber_blocking: fiber_blocking
          ),
          fiber_blocking: fiber_blocking,
          **capabilities
        )
      rescue StandardError
        SchedulerSnapshot.new(scheduler_present: nil, fiber_blocking: nil)
      end

      def capability_measurements(scheduler)
        (CORE_HOOKS + OPTIONAL_HOOKS).to_h do |name|
          [:"scheduler_#{name}_supported", scheduler&.respond_to?(name)]
        end
      end
      private_class_method :capability_measurements

      def snapshot_consistent(scheduler:, current_scheduler:, current_scheduler_supported:, fiber_blocking:)
        return nil unless current_scheduler_supported
        return nil if fiber_blocking.nil?
        return current_scheduler.nil? if scheduler.nil?

        fiber_blocking ? current_scheduler.nil? : current_scheduler.equal?(scheduler)
      end
      private_class_method :snapshot_consistent
    end
  end
end
