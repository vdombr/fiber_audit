# frozen_string_literal: true

require_relative 'validation'

module FiberAudit
  module Runtime
    OperationLivenessPolicy = Data.define(:enabled, :poll_interval_ms, :long_active_threshold_ms) do
      def initialize(**values)
        unknown = values.keys - OperationLivenessPolicy::DEFAULTS.keys
        raise RuntimeContractError, "unknown operation liveness policy field: #{unknown.first}" unless unknown.empty?

        fields = OperationLivenessPolicy::DEFAULTS.merge(values)
        raise RuntimeContractError, 'enabled must be a Boolean' unless [true, false].include?(fields[:enabled])

        limits = OperationLivenessPolicy::LIMITS.to_h do |name, range|
          value = fields.fetch(name)
          unless value.is_a?(Integer) && range.cover?(value)
            raise RuntimeContractError, "#{name} must be an Integer in #{range}"
          end

          [name, value]
        end
        super(enabled: fields[:enabled], **limits)
      end

      def enabled? = enabled
      def poll_interval_ns = poll_interval_ms * OperationLivenessPolicy::NANOSECONDS_PER_MILLISECOND
      def long_active_threshold_ns = long_active_threshold_ms * OperationLivenessPolicy::NANOSECONDS_PER_MILLISECOND

      def long_active?(age_ns:)
        Validation.integer(age_ns, 'active operation age') > long_active_threshold_ns
      end
    end

    OperationLivenessPolicy.const_set(:NANOSECONDS_PER_MILLISECOND, 1_000_000)
    OperationLivenessPolicy.const_set(:DEFAULTS, {
      enabled: true,
      poll_interval_ms: 100,
      long_active_threshold_ms: 1_000
    }.freeze)
    OperationLivenessPolicy.const_set(:LIMITS, {
      poll_interval_ms: 1..60_000,
      long_active_threshold_ms: 1..86_400_000
    }.freeze)
    OperationLivenessPolicy.const_set(:DISABLED, OperationLivenessPolicy.new(enabled: false))
  end
end
