# frozen_string_literal: true

require 'securerandom'
require_relative 'clock'
require_relative 'environment'
require_relative 'jsonl/writer'
require_relative 'recorder'
require_relative 'session'

module FiberAudit
  module Runtime
    class Lifecycle
      attr_reader :settings, :owner_pid, :output_path, :recorder

      def self.start(...)
        new(...)
      end

      def initialize(
        settings:,
        clock: Clock.new,
        session_id_source: SecureRandom.method(:uuid),
        pid_source: Process.method(:pid),
        writer_factory: JSONL::Writer.method(:open),
        random: Sampler::RANDOM_SOURCE
      )
        validate_dependencies!(settings, clock, session_id_source, pid_source, writer_factory, random)
        @settings = settings
        @clock = clock
        @session_id_source = session_id_source
        @pid_source = pid_source
        @writer_factory = writer_factory
        @random = random
        @owner_pid = current_pid
        @state = :starting
        @output_path = nil
        @recorder = nil
        start_process_session!
      rescue StandardError => e
        startup_failure!(e)
      end

      def active?
        @state == :active && recorder&.active?
      end

      def disabled?
        @state == :disabled || recorder&.disabled?
      end

      def closed?
        @state == :closed
      end

      def ensure_current_process!
        pid = current_pid
        return self if pid == owner_pid

        abandon_inherited_writer!
        @owner_pid = pid
        @output_path = nil
        @recorder = nil
        @state = :starting
        start_process_session!
        self
      rescue StandardError => e
        process_failure!(e)
      end

      def shutdown(exception: nil)
        ensure_current_process!
        return @summary if closed?

        @summary = recorder&.close(status: shutdown_status(exception))
        @state = :closed
        @summary
      rescue StandardError => e
        @state = :closed
        raise e unless settings.policy.fail_open?

        nil
      end

      private

      def validate_dependencies!(candidate_settings, candidate_clock, session_ids, pids, writers, random)
        unless candidate_settings.is_a?(Environment::Settings)
          raise RuntimeContractError, 'settings must be FiberAudit::Runtime::Environment::Settings'
        end
        raise RuntimeContractError, 'clock must be a FiberAudit::Runtime::Clock' unless candidate_clock.is_a?(Clock)

        {
          'session_id_source' => session_ids,
          'pid_source' => pids,
          'writer_factory' => writers,
          'random source' => random
        }.each do |name, source|
          raise RuntimeContractError, "#{name} must respond to call" unless source.respond_to?(:call)
        end
      end

      def start_process_session!
        session_id = @session_id_source.call
        started_at = @clock.wall_time
        started_monotonic_ns = @clock.monotonic_ns
        @output_path = build_output_path(session_id)
        session = Session.new(
          id: session_id,
          started_at: started_at,
          started_monotonic_ns: started_monotonic_ns,
          policy: settings.policy
        )
        writer = @writer_factory.call(path: output_path, max_record_bytes: settings.policy.max_record_bytes)
        @recorder = start_recorder(session, writer)
        @state = recorder.active? ? :active : :disabled
      end

      def start_recorder(session, writer)
        Recorder.start(session: session, writer: writer, clock: @clock, random: @random)
      rescue StandardError
        begin
          writer.close
        rescue StandardError
          nil
        end
        raise
      end

      def build_output_path(session_id)
        unless session_id.is_a?(String) && session_id.match?(Validation::UUID)
          raise RuntimeContractError, 'session ID source must return a canonical lowercase UUID'
        end

        filename = "fiber-audit-runtime-#{settings.launch_id}-#{owner_pid}-#{session_id}.jsonl"
        File.join(settings.output_directory, filename).freeze
      end

      def abandon_inherited_writer!
        recorder&.writer&.close
      ensure
        @recorder = nil
      end

      def startup_failure!(error)
        raise error unless defined?(@settings) && settings.policy.fail_open?

        @state = :disabled
      end

      def process_failure!(error)
        raise error unless settings.policy.fail_open?

        @state = :disabled
        self
      end

      def current_pid
        value = @pid_source.call
        unless value.is_a?(Integer) && value.positive?
          raise RuntimeContractError, 'pid source must return a positive Integer'
        end

        value
      end

      def shutdown_status(exception)
        return :completed if exception.nil? || exception.is_a?(SystemExit)

        :aborted
      end
    end
  end
end
