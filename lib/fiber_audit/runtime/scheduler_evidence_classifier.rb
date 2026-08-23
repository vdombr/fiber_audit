# frozen_string_literal: true

require_relative '../operation_semantics'
require_relative 'scheduler_snapshot'

module FiberAudit
  module Runtime
    module SchedulerEvidenceClassifier
      module_function

      def measurements(operation:, scheduler_snapshot:)
        unless scheduler_snapshot.nil? || scheduler_snapshot.is_a?(SchedulerSnapshot)
          raise RuntimeContractError, 'scheduler_snapshot must be a SchedulerSnapshot or nil'
        end

        profile = OperationSemantics.resolve_runtime_operation(operation)
        capability_supported = capability_supported(profile.scheduler_capability, scheduler_snapshot)
        {
          operation_wait_possible: profile.wait_possible,
          operation_inventory_only: profile.inventory_only,
          operation_scheduler_capability_required: profile.known? ? profile.scheduler_capability_required? : nil,
          operation_scheduler_capability_supported: capability_supported,
          operation_scheduler_cooperation_available: cooperation_available(
            profile,
            scheduler_snapshot,
            capability_supported
          )
        }.freeze
      end

      def capability_supported(capability, snapshot)
        return nil if capability.nil? || snapshot.nil?

        case capability
        when :block, :kernel_sleep
          snapshot.scheduler_present
        when :io_select
          snapshot.scheduler_io_select_supported
        when :process_wait
          snapshot.scheduler_process_wait_supported
        when :address_resolve
          snapshot.scheduler_address_resolve_supported
        end
      end
      private_class_method :capability_supported

      def cooperation_available(profile, snapshot, capability_supported)
        return nil unless profile.wait_possible == true
        return nil if snapshot.nil? || snapshot.scheduler_present.nil?
        return false unless snapshot.scheduler_present
        return nil if snapshot.fiber_blocking.nil?
        return false if snapshot.fiber_blocking
        return nil unless profile.scheduler_capability_required?

        capability_supported
      end
      private_class_method :cooperation_available
    end
  end
end
