# frozen_string_literal: true

require_relative 'policy'
require_relative 'session'
require_relative 'validation'

module FiberAudit
  module Runtime
    class Limits
      WINDOW_NS = 1_000_000_000
      MAX_COUNTER = 9_223_372_036_854_775_807
      COUNTERS = SessionSummary::COUNTERS
      DROP_REASONS = %i[
        sampled_out rate_limited session_event_limited session_byte_limited oversize
      ].freeze

      attr_reader :policy, :started_monotonic_ns

      def initialize(policy:, started_monotonic_ns:)
        raise RuntimeContractError, 'policy must be a FiberAudit::Runtime::Policy' unless policy.is_a?(Policy)

        @policy = policy
        @started_monotonic_ns = Validation.integer(started_monotonic_ns, 'started_monotonic_ns')
        @counters = COUNTERS.to_h { |name| [name, 0] }
        @window_index = 0
        @emitted_in_window = 0
        @last_admission_ns = @started_monotonic_ns
      end

      def observe!
        increment!(:events_observed)
      end

      def sampled_out!
        increment!(:sampled_out)
      end

      def preflight_event(now_ns:)
        now = normalize_admission_time(now_ns)
        advance_window!(now)
        return :session_event_limited unless policy.session_event_allowed?(emitted_events: @counters[:events_emitted])
        return :rate_limited unless policy.rate_allowed?(emitted_in_window: @emitted_in_window)

        nil
      end

      def drop!(reason)
        raise RuntimeContractError, "unknown runtime drop reason: #{reason.inspect}" unless DROP_REASONS.include?(reason)

        increment!(reason)
      end

      def emitted!(now_ns:)
        now = normalize_admission_time(now_ns)
        advance_window!(now)
        increment!(:events_emitted)
        increment_window!
      end

      def internal_error!(count: 1)
        amount = Validation.integer(count, 'internal error count', minimum: 1)
        increment!(:internal_errors, amount)
      end

      def counters
        @counters.dup.freeze
      end

      private

      def normalize_admission_time(value)
        now = Validation.integer(value, 'admission monotonic time')
        raise RuntimeContractError, 'admission monotonic time precedes the session' if now < @started_monotonic_ns
        raise RuntimeSafetyError, 'monotonic clock moved backwards' if now < @last_admission_ns

        @last_admission_ns = now
      end

      def advance_window!(now)
        index = (now - started_monotonic_ns) / WINDOW_NS
        return if index == @window_index

        @window_index = index
        @emitted_in_window = 0
      end

      def increment!(name, amount = 1)
        following = @counters.fetch(name) + amount
        raise RuntimeSafetyError, "runtime counter overflow: #{name}" if following > MAX_COUNTER

        @counters[name] = following
      end

      def increment_window!
        following = @emitted_in_window + 1
        raise RuntimeSafetyError, 'runtime rate counter overflow' if following > MAX_COUNTER

        @emitted_in_window = following
      end
    end
  end
end
