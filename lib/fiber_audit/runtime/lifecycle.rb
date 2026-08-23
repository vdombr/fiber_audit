# frozen_string_literal: true

require 'securerandom'
require_relative 'clock'
require_relative 'active_operations'
require_relative 'environment'
require_relative 'execution_context'
require_relative 'rails_integration'
require_relative 'jsonl/writer'
require_relative 'recorder'
require_relative 'redactor'
require_relative 'probes/registry'
require_relative 'scheduler_observer'
require_relative 'session'
require_relative 'watchdog'
require_relative 'watchdog_policy'
require_relative 'operation_liveness_monitor'
require_relative 'operation_liveness_policy'

module FiberAudit
  module Runtime
    # rubocop:disable Metrics/ClassLength
    class Lifecycle
      attr_reader :settings, :owner_pid, :output_path, :recorder,
                  :watchdog, :active_operations, :watchdog_policy,
                  :operation_liveness_monitor, :operation_liveness_policy,
                  :redactor, :probe_registry, :execution_context_store,
                  :rails_integration

      def self.start(...)
        new(...)
      end

      def initialize(
        settings:,
        watchdog_policy: nil,
        operation_liveness_policy: nil,
        probes_enabled: false,
        clock: Clock.new,
        session_id_source: SecureRandom.method(:uuid),
        pid_source: Process.method(:pid),
        writer_factory: JSONL::Writer.method(:open),
        random: Sampler::RANDOM_SOURCE
      )
        validate_dependencies!(
          settings, watchdog_policy, operation_liveness_policy, probes_enabled, clock,
          session_id_source, pid_source, writer_factory, random
        )
        @settings = settings
        @watchdog_policy = watchdog_policy
        @operation_liveness_policy = operation_liveness_policy
        @probes_enabled = probes_enabled
        @clock = clock
        @session_id_source = session_id_source
        @pid_source = pid_source
        @writer_factory = writer_factory
        @random = random
        @owner_pid = current_pid
        @state = :starting
        reset_process_components!
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

        abandon_inherited_runtime!
        @owner_pid = pid
        reset_process_components!
        @state = :starting
        # Reset fiber-local context after fork
        ExecutionContext.reset!
        start_process_session!
        self
      rescue StandardError => e
        process_failure!(e)
      end

      def shutdown(exception: nil)
        ensure_current_process!
        return @summary if closed?

        runtime_error = stop_runtime_observers
        status = runtime_error && exception.nil? ? :degraded : shutdown_status(exception)
        @summary = recorder&.close(status: status)
        @state = :closed
        raise runtime_error if runtime_error && !settings.policy.fail_open?

        @summary
      rescue StandardError => e
        @state = :closed
        raise e unless settings.policy.fail_open?

        nil
      end

      private

      def validate_dependencies!(candidate_settings, watchdog, liveness, probes, candidate_clock,
                                 session_ids, pids, writers, random)
        unless candidate_settings.is_a?(Environment::Settings)
          raise RuntimeContractError, 'settings must be FiberAudit::Runtime::Environment::Settings'
        end
        unless watchdog.nil? || watchdog.is_a?(WatchdogPolicy)
          raise RuntimeContractError, 'watchdog_policy must be a FiberAudit::Runtime::WatchdogPolicy or nil'
        end
        unless liveness.nil? || liveness.is_a?(OperationLivenessPolicy)
          raise RuntimeContractError,
                'operation_liveness_policy must be a FiberAudit::Runtime::OperationLivenessPolicy or nil'
        end
        raise RuntimeContractError, 'probes_enabled must be a Boolean' unless [true, false].include?(probes)
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

      def reset_process_components!
        @output_path = nil
        @recorder = nil
        @watchdog = nil
        @operation_liveness_monitor = nil
        @scheduler_observer = nil
        @active_operations = nil
        @redactor = nil
        @probe_registry = nil
        @execution_context_store = nil
        @rails_integration = nil
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
        setup_runtime_observers! if recorder.active?
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

      def setup_runtime_observers!
        @active_operations = ActiveOperations.new(pid_source: @pid_source)
        @redactor = Redactor.new(root: settings.project_root, policy: settings.policy)
        @execution_context_store = ExecutionContext if @probes_enabled
        setup_watchdog! if watchdog_policy
        setup_operation_liveness! if @probes_enabled && operation_liveness_policy
        setup_rails_integration! if @probes_enabled
        setup_probes! if @probes_enabled
      rescue StandardError => e
        unless e.instance_variable_defined?(:@fiber_audit_runtime_accounted)
          recorder.internal_error!
          e.instance_variable_set(:@fiber_audit_runtime_accounted, true)
        end
        deactivate_active_components!
        close_failed_startup!(e)
      end

      def deactivate_active_components!
        # Deactivate components in reverse order of setup
        begin
          Probes::Registry.deactivate(@probe_registry) if @probe_registry
        rescue StandardError
          nil
        ensure
          @probe_registry = nil
        end
        begin
          RailsIntegration.deactivate(@rails_integration) if @rails_integration
        rescue StandardError
          nil
        ensure
          @rails_integration = nil
        end
        begin
          @operation_liveness_monitor&.stop
        rescue StandardError
          nil
        ensure
          @operation_liveness_monitor = nil
        end
        begin
          if @scheduler_observer
            SchedulerObserver.deactivate(@scheduler_observer)
            @watchdog&.stop
          end
        rescue StandardError
          nil
        ensure
          @scheduler_observer = nil
          @watchdog = nil
        end
      end

      def setup_operation_liveness!
        @operation_liveness_monitor = OperationLivenessMonitor.new(
          policy: operation_liveness_policy,
          recorder: recorder,
          active_operations: active_operations,
          clock: @clock
        )
      end

      def setup_rails_integration!
        @rails_integration = RailsIntegration.activate(
          context_store: @execution_context_store,
          recorder: recorder
        )
      rescue StandardError
        @rails_integration = nil
        raise unless settings.policy.fail_open?
      end

      def setup_watchdog!
        @watchdog = Watchdog.new(
          policy: watchdog_policy,
          recorder: recorder,
          redactor: redactor,
          active_operations: active_operations,
          clock: @clock
        )
        @scheduler_observer = SchedulerObserver.activate(watchdog: watchdog) if watchdog.enabled?
      end

      def setup_probes!
        base = Probes::Base.new(
          recorder: recorder,
          clock: @clock,
          redactor: redactor,
          active_operations: active_operations,
          execution_context_store: @execution_context_store,
          pid_source: @pid_source
        )
        @probe_registry = Probes::Registry.activate(base: base)
      end

      def close_failed_startup!(error)
        @probe_registry = nil
        return if settings.policy.fail_open?

        begin
          recorder.close(status: :degraded)
        rescue StandardError
          nil
        end
        raise error
      end

      def build_output_path(session_id)
        unless session_id.is_a?(String) && session_id.match?(Validation::UUID)
          raise RuntimeContractError, 'session ID source must return a canonical lowercase UUID'
        end

        filename = "fiber-audit-runtime-#{settings.launch_id}-#{owner_pid}-#{session_id}.jsonl"
        File.join(settings.output_directory, filename).freeze
      end

      def abandon_inherited_runtime!
        recorder&.writer&.close
      ensure
        reset_process_components!
      end

      def stop_runtime_observers
        error = nil
        component_error = stop_rails_integration
        error ||= component_error
        component_error = stop_probe_registry
        error ||= component_error
        component_error = stop_operation_liveness_monitor
        error ||= component_error
        component_error = stop_watchdog
        error ||= component_error
        recorder&.internal_error! if error
        error
      end

      def stop_rails_integration
        RailsIntegration.deactivate(@rails_integration) if @rails_integration
        nil
      rescue StandardError => e
        e
      ensure
        @rails_integration = nil
      end

      def stop_probe_registry
        Probes::Registry.deactivate(probe_registry) if probe_registry
        nil
      rescue StandardError => e
        e
      ensure
        @probe_registry = nil
      end

      def stop_operation_liveness_monitor
        operation_liveness_monitor&.stop
        nil
      rescue StandardError => e
        e
      ensure
        @operation_liveness_monitor = nil
      end

      def stop_watchdog
        SchedulerObserver.deactivate(@scheduler_observer) if @scheduler_observer
        watchdog&.stop
        nil
      rescue StandardError => e
        e
      ensure
        @scheduler_observer = nil
        @watchdog = nil
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
    # rubocop:enable Metrics/ClassLength
  end
end
