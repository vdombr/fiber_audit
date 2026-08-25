# frozen_string_literal: true

require_relative 'clock'
require_relative 'event'
require_relative 'jsonl/writer'
require_relative 'limits'
require_relative 'sampler'
require_relative 'session'

module FiberAudit
  module Runtime
    # Thread-safe coordinator for one bounded append-only runtime session.
    # rubocop:disable Metrics/ClassLength
    class Recorder
      RESULTS = %i[
        emitted sampled_out rate_limited session_event_limited session_byte_limited
        oversize internal_error inactive
      ].freeze
      MAX_COUNTER = Limits::MAX_COUNTER
      OUTCOME_COUNTERS = 6

      attr_reader :session, :writer

      def self.start(...)
        new(...)
      end

      def initialize(session:, writer:, clock: Clock.new, random: Sampler::RANDOM_SOURCE)
        validate_dependencies!(session, writer, clock, random)
        @session = session
        @writer = writer
        @clock = clock
        @mutex = Mutex.new
        @state = :starting
        @sequence = 1
        @in_flight = 0
        @start_written = false
        @summary = nil
        @limits = Limits.new(policy: session.policy, started_monotonic_ns: session.started_monotonic_ns)
        @sampler = Sampler.new(policy: session.policy, random: random)
        @end_reserve_bytes = end_reserve_bytes
        start_session!
      rescue StandardError => e
        startup_failure!(e)
      end

      def record(&factory)
        record_observation(sample: true, factory: factory)
      end

      # Control evidence is never sampled, but still consumes every configured
      # rate, count, record-size, and session-size budget.
      def record_control(&factory)
        record_observation(sample: false, factory: factory)
      end

      # Accounts an instrumentation failure without retaining exception data.
      def internal_error!
        @mutex.synchronize do
          return false if @state == :closed

          @limits.internal_error!
          true
        end
      end

      def close(status: :completed)
        requested_status = normalize_status(status)
        @mutex.synchronize do
          return @summary if @summary

          @state = :closing
          @limits.internal_error!(count: @in_flight) if @in_flight.positive?
          ended_at, ended_monotonic_ns, clock_error = closing_times
          errors = [clock_error].compact
          summary = build_summary(requested_status, ended_at, ended_monotonic_ns)
          errors.concat(write_end_record(summary))
          errors.concat(close_writer)
          summary = build_summary(requested_status, ended_at, ended_monotonic_ns) unless errors.empty?
          @summary = summary
          @state = :closed
          raise errors.first if errors.any? && !session.policy.fail_open?

          @summary
        end
      end

      def active?
        state?(:active)
      end

      def disabled?
        state?(:disabled)
      end

      def closed?
        state?(:closed)
      end

      def summary
        @mutex.synchronize { @summary }
      end

      private

      def validate_dependencies!(candidate_session, candidate_writer, candidate_clock, candidate_random)
        raise RuntimeContractError, 'session must be a FiberAudit::Runtime::Session' unless candidate_session.is_a?(Session)
        unless candidate_writer.is_a?(JSONL::Writer)
          raise RuntimeContractError, 'writer must be a FiberAudit::Runtime::JSONL::Writer'
        end
        raise RuntimeContractError, 'clock must be a FiberAudit::Runtime::Clock' unless candidate_clock.is_a?(Clock)
        raise RuntimeContractError, 'random source must respond to call' unless candidate_random.respond_to?(:call)
      end

      def start_session!
        raise RuntimeSafetyError, 'runtime JSONL writer is not empty' unless writer.bytes_written.zero?
        if session.started_monotonic_ns > MAX_COUNTER
          raise RuntimeSafetyError, 'session monotonic start exceeds signed 64-bit range'
        end

        line = writer.prepare(JSONL::Schema.start_record(session))
        required = line.bytesize + @end_reserve_bytes
        unless session.policy.session_bytes_allowed?(written_bytes: 0, next_record_bytes: required)
          raise RuntimeSafetyError, 'runtime session limit cannot contain start and end records'
        end

        writer.write_line(line)
        @start_written = true
        @state = :active
      end

      def startup_failure!(error)
        raise error unless defined?(@session) && session.policy.fail_open?

        @limits&.internal_error!
        @state = :disabled
      end

      def record_observation(sample:, factory:)
        raise ArgumentError, 'record requires an event factory block' unless factory

        decision = begin_observation(sample: sample)
        return decision unless decision == :selected

        completed = false
        begin
          event = factory.call
          completed = true
        ensure
          release_failed_factory unless completed
        end
        finish_observation(event)
      end

      def begin_observation(sample:)
        @mutex.synchronize do
          return :inactive unless @state == :active

          @limits.observe!
          if sample && !@sampler.sample?
            @limits.drop!(:sampled_out)
            return :sampled_out
          end

          @in_flight += 1
          :selected
        rescue StandardError => e
          handle_internal_error!(e)
        end
      end

      def finish_observation(event)
        @mutex.synchronize do
          @in_flight -= 1
          return finish_inactive_observation unless @state == :active

          emit_or_drop(event)
        rescue StandardError => e
          handle_internal_error!(e)
        ensure
          if writer.failed? && @state == :active
            @limits.internal_error!
            @state = :disabled
          end
        end
      end

      def finish_inactive_observation
        @limits.internal_error! if @state == :disabled
        :inactive
      end

      def emit_or_drop(event)
        raise RuntimeContractError, 'event factory must return a FiberAudit::Runtime::Event' unless event.is_a?(Event)

        now_ns = @clock.monotonic_ns
        reason = @limits.preflight_event(now_ns: now_ns)
        return account_preflight_drop(reason) if reason

        line = prepare_event(event)
        return :oversize unless line

        unless event_bytes_allowed?(line)
          @limits.drop!(:session_byte_limited)
          return :session_byte_limited
        end

        writer.write_line(line)
        @limits.emitted!(now_ns: now_ns)
        @sequence += 1
        :emitted
      end

      def account_preflight_drop(reason)
        @limits.drop!(reason)
        reason
      end

      def prepare_event(event)
        record = JSONL::Schema.event_record(
          session_id: session.id,
          sequence: @sequence,
          event: event,
          schema_version: session.schema_version
        )
        writer.prepare(record)
      rescue RuntimeSafetyError
        @limits.drop!(:oversize)
        nil
      end

      def event_bytes_allowed?(line)
        required = line.bytesize + @end_reserve_bytes
        session.policy.session_bytes_allowed?(
          written_bytes: writer.bytes_written,
          next_record_bytes: required
        )
      end

      def release_failed_factory
        @mutex.synchronize do
          @in_flight -= 1
          @limits.internal_error! if @state == :disabled
        end
      end

      def handle_internal_error!(error)
        @limits.internal_error!
        @state = :disabled
        raise error unless session.policy.fail_open?

        :internal_error
      end

      def closing_times
        [@clock.wall_time, @clock.monotonic_ns, nil]
      rescue StandardError => e
        @limits.internal_error!
        [session.started_at, session.started_monotonic_ns, e]
      end

      def write_end_record(summary)
        return [] unless @start_written && writer.active?

        record = JSONL::Schema.end_record(
          session_id: session.id,
          sequence: @sequence,
          summary: summary,
          schema_version: session.schema_version
        )
        line = writer.prepare(record)
        if line.bytesize > @end_reserve_bytes
          raise RuntimeSafetyError, 'runtime session end record exceeded its reserved bytes'
        end
        unless session.policy.session_bytes_allowed?(written_bytes: writer.bytes_written, next_record_bytes: line.bytesize)
          raise RuntimeSafetyError, 'runtime session end record exceeded the session byte limit'
        end

        writer.write_line(line)
        []
      rescue StandardError => e
        @limits.internal_error!
        [e]
      end

      def close_writer
        writer.close
        []
      rescue StandardError => e
        @limits.internal_error!
        [e]
      end

      def build_summary(requested_status, ended_at, ended_monotonic_ns)
        status = summary_status(requested_status)
        SessionSummary.new(
          ended_at: ended_at,
          ended_monotonic_ns: ended_monotonic_ns,
          status: status,
          **@limits.counters
        )
      end

      def summary_status(requested)
        return :aborted if requested == :aborted
        return :degraded if requested == :degraded || @limits.counters[:internal_errors].positive?

        :completed
      end

      def normalize_status(value)
        normalized = value.is_a?(String) || value.is_a?(Symbol) ? value.to_sym : nil
        return normalized if SessionSummary::STATUSES.include?(normalized)

        raise RuntimeContractError, "status must be one of: #{SessionSummary::STATUSES.join(', ')}"
      end

      def end_reserve_bytes
        outcome = MAX_COUNTER / OUTCOME_COUNTERS
        summary = SessionSummary.new(
          ended_at: session.started_at,
          ended_monotonic_ns: MAX_COUNTER,
          status: :completed,
          events_observed: outcome * OUTCOME_COUNTERS,
          events_emitted: outcome,
          sampled_out: outcome,
          rate_limited: outcome,
          session_event_limited: outcome,
          session_byte_limited: outcome,
          oversize: outcome,
          internal_errors: MAX_COUNTER
        )
        record = JSONL::Schema.end_record(
          session_id: session.id,
          sequence: MAX_COUNTER,
          summary: summary,
          schema_version: session.schema_version
        )
        writer.prepare(record).bytesize
      end

      def state?(expected)
        @mutex.synchronize { @state == expected }
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
