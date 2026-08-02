# frozen_string_literal: true

require_relative '../version'
require_relative 'policy'
require_relative 'validation'

module FiberAudit
  module Runtime
    Session = Data.define(
      :id,
      :started_at,
      :started_monotonic_ns,
      :policy,
      :tool_version,
      :ruby_version
    ) do
      def initialize(
        id:,
        started_at:,
        started_monotonic_ns:,
        policy: Policy.new,
        tool_version: FiberAudit::VERSION,
        ruby_version: RUBY_VERSION
      )
        super(
          id: normalize_id(id),
          started_at: Validation.utc_time(started_at, 'started_at'),
          started_monotonic_ns: Validation.integer(started_monotonic_ns, 'started_monotonic_ns'),
          policy: normalize_policy(policy),
          tool_version: Validation.string(tool_version, 'tool_version', max_bytes: 64),
          ruby_version: Validation.string(ruby_version, 'ruby_version', max_bytes: 64)
        )
      end

      private

      def normalize_id(value)
        unless value.is_a?(String) && value.match?(Validation::UUID)
          raise RuntimeContractError, 'id must be a canonical lowercase UUID'
        end

        value.dup.freeze
      end

      def normalize_policy(value)
        return value if value.is_a?(Policy)

        raise RuntimeContractError, 'policy must be a FiberAudit::Runtime::Policy'
      end
    end

    SessionSummary = Data.define(
      :ended_at,
      :ended_monotonic_ns,
      :status,
      :events_observed,
      :events_emitted,
      :sampled_out,
      :rate_limited,
      :session_event_limited,
      :session_byte_limited,
      :oversize,
      :internal_errors
    ) do
      def initialize(ended_at:, ended_monotonic_ns:, status:, **counters)
        unknown = counters.keys - SessionSummary::COUNTERS
        missing = SessionSummary::COUNTERS - counters.keys
        raise RuntimeContractError, "unknown session summary field: #{unknown.first}" unless unknown.empty?
        raise RuntimeContractError, "missing session summary field: #{missing.first}" unless missing.empty?

        normalized_status = status.is_a?(String) || status.is_a?(Symbol) ? status.to_sym : nil
        unless SessionSummary::STATUSES.include?(normalized_status)
          raise RuntimeContractError, "status must be one of: #{SessionSummary::STATUSES.join(', ')}"
        end

        normalized_counters = counters.to_h do |name, value|
          [name, Validation.integer(value, name.to_s)]
        end
        accounted = %i[
          events_emitted
          sampled_out
          rate_limited
          session_event_limited
          session_byte_limited
          oversize
        ].sum { |name| normalized_counters.fetch(name) }
        if accounted > normalized_counters.fetch(:events_observed)
          raise RuntimeContractError, 'event accounting exceeds events_observed'
        end

        super(
          ended_at: Validation.utc_time(ended_at, 'ended_at'),
          ended_monotonic_ns: Validation.integer(ended_monotonic_ns, 'ended_monotonic_ns'),
          status: normalized_status,
          **normalized_counters
        )
      end
    end

    SessionSummary.const_set(:STATUSES, %i[completed degraded aborted].freeze)
    SessionSummary.const_set(:COUNTERS, %i[
      events_observed
      events_emitted
      sampled_out
      rate_limited
      session_event_limited
      session_byte_limited
      oversize
      internal_errors
    ].freeze)
  end
end
