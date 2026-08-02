# frozen_string_literal: true

require_relative '../execution_context'
require_relative 'location'
require_relative 'validation'

module FiberAudit
  module Runtime
    Event = Data.define(
      :kind,
      :source,
      :occurred_at,
      :monotonic_ns,
      :duration_ns,
      :operation,
      :location,
      :execution_context,
      :thread_id,
      :fiber_id,
      :measurements
    ) do
      def initialize(
        kind:,
        source:,
        occurred_at:,
        monotonic_ns:,
        duration_ns: nil,
        operation: nil,
        location: nil,
        execution_context: :unknown,
        thread_id: nil,
        fiber_id: nil,
        measurements: {}
      )
        super(
          kind: Validation.identifier(kind, 'kind'),
          source: Validation.identifier(source, 'source'),
          occurred_at: Validation.utc_time(occurred_at, 'occurred_at'),
          monotonic_ns: Validation.integer(monotonic_ns, 'monotonic_ns'),
          duration_ns: Validation.integer(duration_ns, 'duration_ns', allow_nil: true),
          operation: Validation.operation(operation, allow_nil: true),
          location: normalize_location(location),
          execution_context: normalize_context(execution_context),
          thread_id: Validation.integer(thread_id, 'thread_id', allow_nil: true),
          fiber_id: Validation.integer(fiber_id, 'fiber_id', allow_nil: true),
          measurements: normalize_measurements(measurements)
        )
      end

      private

      def normalize_location(value)
        return value if value.nil? || value.is_a?(Location)

        raise RuntimeContractError, 'location must be a FiberAudit::Runtime::Location or nil'
      end

      def normalize_context(value)
        normalized = value.is_a?(String) || value.is_a?(Symbol) ? value.to_sym : nil
        return normalized if Context::ALL.include?(normalized)

        raise RuntimeContractError, "execution_context is invalid: #{value.inspect}"
      end

      def normalize_measurements(value)
        raise RuntimeContractError, 'measurements must be a Hash' unless value.is_a?(Hash)
        if value.size > Event::MAX_MEASUREMENTS
          raise RuntimeContractError, "measurements must contain at most #{Event::MAX_MEASUREMENTS} entries"
        end

        value.each_with_object({}) do |(key, measurement), normalized|
          name = Validation.identifier(key, 'measurement key').to_s.freeze
          raise RuntimeContractError, "duplicate normalized measurement key: #{name}" if normalized.key?(name)
          unless measurement.nil? || measurement == true || measurement == false ||
                 (measurement.is_a?(Numeric) && measurement.finite?)
            raise RuntimeContractError, "measurement #{name} must be a finite number, Boolean, or nil"
          end

          normalized[name] = measurement
        end.freeze
      end
    end

    Event.const_set(:MAX_MEASUREMENTS, 32)
  end
end
