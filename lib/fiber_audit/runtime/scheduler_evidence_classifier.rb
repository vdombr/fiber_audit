# frozen_string_literal: true

require_relative '../operation_semantics'
require_relative 'scheduler_snapshot'

module FiberAudit
  module Runtime
    # Central truth table for scheduler evidence classification.
    # rubocop:disable Metrics/ModuleLength
    module SchedulerEvidenceClassifier
      CAPABILITY_FIELDS = {
        block: :scheduler_block_supported,
        kernel_sleep: :scheduler_kernel_sleep_supported,
        io_wait: :scheduler_io_wait_supported,
        io_select: :scheduler_io_select_supported,
        process_wait: :scheduler_process_wait_supported,
        address_resolve: :scheduler_address_resolve_supported
      }.freeze
      INVOCATION_KEYS = %i[timeout_present timeout_zero endpoint_resolution_applicable].freeze

      module_function

      def measurements(operation:, scheduler_snapshot:, invocation_measurements: {})
        unless scheduler_snapshot.nil? || scheduler_snapshot.is_a?(SchedulerSnapshot)
          raise RuntimeContractError, 'scheduler_snapshot must be a SchedulerSnapshot or nil'
        end
        raise RuntimeContractError, 'invocation_measurements must be a Hash' unless invocation_measurements.is_a?(Hash)

        profile = OperationSemantics.resolve_runtime_operation(operation)
        return unknown_measurements unless profile.known?

        core = classify_requirements(profile.core_capabilities, scheduler_snapshot, invocation_measurements)
        optional = classify_requirements(profile.optional_capabilities, scheduler_snapshot, invocation_measurements)
        {
          operation_wait_possible: profile.wait_possible,
          operation_inventory_only: profile.inventory_only,
          operation_core_capability_required: !profile.core_capabilities.empty?,
          operation_core_capability_supported: core.fetch(:supported),
          operation_optional_capability_required: !profile.optional_capabilities.empty?,
          operation_optional_capability_applicable: optional.fetch(:applicable),
          operation_optional_capability_supported: optional.fetch(:supported),
          operation_scheduler_cooperation_available: cooperation_available(
            profile: profile, snapshot: scheduler_snapshot, core: core, optional: optional
          )
        }.freeze
      end

      def unknown_measurements
        {
          operation_wait_possible: nil, operation_inventory_only: nil,
          operation_core_capability_required: nil, operation_core_capability_supported: nil,
          operation_optional_capability_required: nil, operation_optional_capability_applicable: nil,
          operation_optional_capability_supported: nil, operation_scheduler_cooperation_available: nil
        }.freeze
      end
      private_class_method :unknown_measurements

      def classify_requirements(requirements, snapshot, invocation_measurements)
        return { applicable: true, supported: nil }.freeze if requirements.empty?

        applicability = requirements.map { |r| requirement_applicability(r, invocation_measurements) }
        applicable = aggregate_applicability(applicability)
        support_values = requirements.each_with_index.map do |requirement, index|
          next unless applicability[index] == true

          capability_supported(requirement.name, snapshot)
        end.compact
        supported = applicability.any?(&:nil?) ? nil : aggregate_support(support_values)
        { applicable: applicable, supported: supported }.freeze
      end
      private_class_method :classify_requirements

      def requirement_applicability(requirement, measurements)
        return true unless requirement.conditional?

        case requirement.name
        when :io_select
          timeout_zero = invocation_value(measurements, :timeout_zero)
          timeout_zero.nil? ? nil : !timeout_zero
        when :address_resolve
          invocation_value(measurements, :endpoint_resolution_applicable)
        end
      end
      private_class_method :requirement_applicability

      def invocation_value(measurements, key)
        value = measurements.key?(key) ? measurements[key] : measurements[key.to_s]
        return value if value.nil? || [true, false].include?(value)

        raise RuntimeContractError, "#{key} must be a Boolean or nil"
      end
      private_class_method :invocation_value

      def aggregate_applicability(values)
        return true if values.any?(true)
        return nil if values.any?(&:nil?)

        false
      end
      private_class_method :aggregate_applicability

      def aggregate_support(values)
        return nil if values.empty?
        return false if values.any?(false)
        return nil if values.any?(&:nil?)

        true
      end
      private_class_method :aggregate_support

      def capability_supported(capability, snapshot)
        return nil if snapshot.nil?

        snapshot.public_send(CAPABILITY_FIELDS.fetch(capability))
      end
      private_class_method :capability_supported

      # Ordered tri-state checks intentionally mirror the evidence contract.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def cooperation_available(profile:, snapshot:, core:, optional:)
        return nil unless profile.wait_possible == true
        return nil if snapshot.nil? || snapshot.scheduler_present.nil?
        return false unless snapshot.scheduler_present
        return nil unless snapshot.scheduler_snapshot_consistent == true
        return nil if snapshot.fiber_blocking.nil?
        return false if snapshot.fiber_blocking
        return nil unless profile.scheduler_capability_required?
        return false if core.fetch(:supported) == false
        return nil if core.fetch(:supported).nil? && !profile.core_capabilities.empty?

        unless profile.optional_capabilities.empty?
          return nil if optional.fetch(:applicable).nil?
          return false if optional.fetch(:applicable) && optional.fetch(:supported) == false
          return nil if optional.fetch(:applicable) && optional.fetch(:supported).nil?
        end

        true
      end
      private_class_method :cooperation_available
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
