# frozen_string_literal: true

require_relative 'validation'

module FiberAudit
  module Runtime
    WatchdogPolicy = Data.define(
      :enabled,
      :heartbeat_interval_ms,
      :stall_threshold_ms,
      :max_frames
    ) do
      def initialize(**values)
        unknown = values.keys - WatchdogPolicy::DEFAULTS.keys
        raise RuntimeContractError, "unknown watchdog policy field: #{unknown.first}" unless unknown.empty?

        fields = WatchdogPolicy::DEFAULTS.merge(values)
        raise RuntimeContractError, 'enabled must be a Boolean' unless [true, false].include?(fields[:enabled])

        limits = WatchdogPolicy::LIMITS.to_h do |name, range|
          value = fields.fetch(name)
          unless value.is_a?(Integer) && range.cover?(value)
            raise RuntimeContractError, "#{name} must be an Integer in #{range}"
          end

          [name, value]
        end

        super(enabled: fields[:enabled], **limits)
      end

      def enabled?
        enabled
      end

      def heartbeat_interval_ns
        heartbeat_interval_ms * WatchdogPolicy::NANOSECONDS_PER_MILLISECOND
      end

      def stall_threshold_ns
        stall_threshold_ms * WatchdogPolicy::NANOSECONDS_PER_MILLISECOND
      end

      def stalled?(age_ns:)
        age = Validation.integer(age_ns, 'heartbeat age')
        age > stall_threshold_ns
      end
    end

    WatchdogPolicy.const_set(:NANOSECONDS_PER_MILLISECOND, 1_000_000)
    WatchdogPolicy.const_set(:DEFAULTS, {
      enabled: true,
      heartbeat_interval_ms: 25,
      stall_threshold_ms: 100,
      max_frames: 20
    }.freeze)
    WatchdogPolicy.const_set(:LIMITS, {
      heartbeat_interval_ms: 1..60_000,
      stall_threshold_ms: 1..600_000,
      max_frames: 0..100
    }.freeze)
    WatchdogPolicy.const_set(:DISABLED, WatchdogPolicy.new(enabled: false))
  end
end
