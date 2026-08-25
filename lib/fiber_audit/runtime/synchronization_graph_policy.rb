# frozen_string_literal: true

module FiberAudit
  module Runtime
    SynchronizationGraphPolicy = Data.define(
      :enabled,
      :max_identities,
      :max_resources,
      :max_wait_edges,
      :max_cycle_depth
    ) do
      def initialize(**values)
        unknown = values.keys - SynchronizationGraphPolicy::DEFAULTS.keys
        raise RuntimeContractError, "unknown synchronization graph policy field: #{unknown.first}" unless unknown.empty?

        fields = SynchronizationGraphPolicy::DEFAULTS.merge(values)
        raise RuntimeContractError, 'enabled must be a Boolean' unless [true, false].include?(fields[:enabled])

        limits = SynchronizationGraphPolicy::LIMITS.to_h do |name, range|
          value = fields.fetch(name)
          unless value.is_a?(Integer) && range.cover?(value)
            raise RuntimeContractError, "#{name} must be an Integer in #{range}"
          end

          [name, value]
        end
        super(enabled: fields[:enabled], **limits)
      end

      def enabled? = enabled
    end

    SynchronizationGraphPolicy.const_set(:DEFAULTS, {
      enabled: false, max_identities: 4_096, max_resources: 2_048,
      max_wait_edges: 2_048, max_cycle_depth: 64
    }.freeze)
    SynchronizationGraphPolicy.const_set(:LIMITS, {
      max_identities: 1..100_000, max_resources: 1..100_000,
      max_wait_edges: 1..100_000, max_cycle_depth: 2..256
    }.freeze)
    SynchronizationGraphPolicy.const_set(:DISABLED, SynchronizationGraphPolicy.new(enabled: false))
  end
end
