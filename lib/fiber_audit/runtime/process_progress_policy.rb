# frozen_string_literal: true

require_relative 'validation'

module FiberAudit
  module Runtime
    ProcessProgressPolicy = Data.define(
      :enabled, :heartbeat_interval_ms, :stall_threshold_ms, :max_processes,
      :max_frames_per_poll, :max_buffer_bytes
    ) do
      def initialize(**values)
        unknown = values.keys - ProcessProgressPolicy::DEFAULTS.keys
        raise RuntimeContractError, "unknown process progress policy field: #{unknown.first}" unless unknown.empty?

        fields = ProcessProgressPolicy::DEFAULTS.merge(values)
        raise RuntimeContractError, 'enabled must be a Boolean' unless [true, false].include?(fields[:enabled])

        limits = ProcessProgressPolicy::LIMITS.to_h do |name, range|
          value = fields.fetch(name)
          unless value.is_a?(Integer) && range.cover?(value)
            raise RuntimeContractError, "#{name} must be an Integer in #{range}"
          end

          [name, value]
        end
        raise RuntimeContractError, 'stall_threshold_ms must be greater than heartbeat_interval_ms' \
          unless limits[:stall_threshold_ms] > limits[:heartbeat_interval_ms]

        super(enabled: fields[:enabled], **limits)
      end

      def enabled? = enabled
      def heartbeat_interval_ns = heartbeat_interval_ms * ProcessProgressPolicy::NANOSECONDS_PER_MILLISECOND
      def stall_threshold_ns = stall_threshold_ms * ProcessProgressPolicy::NANOSECONDS_PER_MILLISECOND

      def stalled?(age_ns:)
        Validation.integer(age_ns, 'process progress age') > stall_threshold_ns
      end
    end

    ProcessProgressPolicy.const_set(:NANOSECONDS_PER_MILLISECOND, 1_000_000)
    ProcessProgressPolicy.const_set(:DEFAULTS, {
      enabled: false, heartbeat_interval_ms: 50, stall_threshold_ms: 250,
      max_processes: 1_024, max_frames_per_poll: 256, max_buffer_bytes: 65_536
    }.freeze)
    ProcessProgressPolicy.const_set(:LIMITS, {
      heartbeat_interval_ms: 1..60_000, stall_threshold_ms: 2..600_000,
      max_processes: 1..100_000, max_frames_per_poll: 1..10_000,
      max_buffer_bytes: 80..1_048_576
    }.freeze)
    ProcessProgressPolicy.const_set(:DISABLED, ProcessProgressPolicy.new(enabled: false))
  end
end
