# frozen_string_literal: true

require_relative 'validation'

module FiberAudit
  module Runtime
    Policy = Data.define(
      :redaction,
      :sampling_rate,
      :max_events_per_second,
      :max_events_per_session,
      :max_record_bytes,
      :max_session_bytes,
      :fail_open
    ) do
      def initialize(**values)
        unknown = values.keys - Policy::DEFAULTS.keys
        raise RuntimeContractError, "unknown runtime policy field: #{unknown.first}" unless unknown.empty?

        fields = Policy::DEFAULTS.merge(values)
        redaction = normalize_redaction(fields[:redaction])
        sampling_rate = normalize_sampling_rate(fields[:sampling_rate])
        limits = Policy::LIMITS.to_h do |name, range|
          [name, normalize_limit(fields[name], name, range)]
        end
        unless limits[:max_session_bytes] >= limits[:max_record_bytes]
          raise RuntimeContractError, 'max_session_bytes must be >= max_record_bytes'
        end
        raise RuntimeContractError, 'fail_open must be a Boolean' unless [true, false].include?(fields[:fail_open])

        super(
          redaction: redaction,
          sampling_rate: sampling_rate,
          **limits,
          fail_open: fields[:fail_open]
        )
      end

      def sample?(draw:)
        value = Validation.finite_number(draw, 'draw').to_f
        raise RuntimeContractError, 'draw must be in 0.0...1.0' unless value >= 0.0 && value < 1.0

        value < sampling_rate
      end

      def rate_allowed?(emitted_in_window:)
        count_below_limit?(emitted_in_window, max_events_per_second, 'emitted_in_window')
      end

      def session_event_allowed?(emitted_events:)
        count_below_limit?(emitted_events, max_events_per_session, 'emitted_events')
      end

      def record_size_allowed?(bytes:)
        size_allowed?(bytes, max_record_bytes, 'bytes')
      end

      def session_bytes_allowed?(written_bytes:, next_record_bytes:)
        written = Validation.integer(written_bytes, 'written_bytes')
        following = Validation.integer(next_record_bytes, 'next_record_bytes')
        written + following <= max_session_bytes
      end

      def fail_open?
        fail_open
      end

      def strict_redaction?
        redaction == :strict
      end

      private

      def normalize_redaction(value)
        normalized = value.is_a?(String) || value.is_a?(Symbol) ? value.to_sym : nil
        return :strict if normalized == :strict

        raise RuntimeContractError, 'redaction must be strict'
      end

      def normalize_sampling_rate(value)
        rate = Validation.finite_number(value, 'sampling_rate').to_f
        return rate if rate.between?(0.0, 1.0)

        raise RuntimeContractError, 'sampling_rate must be between 0.0 and 1.0'
      end

      def normalize_limit(value, field, range)
        unless value.is_a?(Integer) && range.cover?(value)
          raise RuntimeContractError, "#{field} must be an Integer in #{range}"
        end

        value
      end

      def count_below_limit?(value, limit, field)
        Validation.integer(value, field) < limit
      end

      def size_allowed?(value, limit, field)
        Validation.integer(value, field) <= limit
      end
    end

    Policy.const_set(:DEFAULTS, {
      redaction: :strict,
      sampling_rate: 0.1,
      max_events_per_second: 100,
      max_events_per_session: 10_000,
      max_record_bytes: 16_384,
      max_session_bytes: 10_485_760,
      fail_open: true
    }.freeze)
    Policy.const_set(:LIMITS, {
      max_events_per_second: 1..10_000,
      max_events_per_session: 1..1_000_000,
      max_record_bytes: 1_024..1_048_576,
      max_session_bytes: 4_096..1_073_741_824
    }.freeze)
  end
end
