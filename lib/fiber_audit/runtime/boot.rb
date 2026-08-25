# frozen_string_literal: true

require 'English'
require_relative 'environment'
require_relative 'lifecycle'

module FiberAudit
  module Runtime
    module Boot
      class << self
        # Activation is a stable orchestration boundary with ordered resource ownership.
        # rubocop:disable Metrics/MethodLength
        def activate_from_environment!(
          environment: ENV,
          clock: Clock.new,
          session_id_source: SecureRandom.method(:uuid),
          pid_source: Process.method(:pid),
          writer_factory: JSONL::Writer.method(:open),
          random: Sampler::RANDOM_SOURCE
        )
          return current if activated_for_current_process?

          mode = Environment.failure_mode(environment)
          return unless Environment.activated?(environment)

          settings = Environment.load(environment)
          watchdog_policy = if environment.key?(Environment::WATCHDOG_SETTINGS_KEY)
                              Environment.load_watchdog_policy(environment)
                            end
          operation_liveness_policy = if environment.key?(Environment::OPERATION_LIVENESS_SETTINGS_KEY)
                                        Environment.load_operation_liveness_policy(environment)
                                      end
          synchronization_graph_policy = if environment.key?(Environment::SYNCHRONIZATION_GRAPH_SETTINGS_KEY)
                                           Environment.load_synchronization_graph_policy(environment)
                                         end
          process_progress_policy = if environment.key?(Environment::PROCESS_PROGRESS_SETTINGS_KEY)
                                      Environment.load_process_progress_policy(environment)
                                    end
          process_progress_writer = if process_progress_policy&.enabled?
                                      Environment.open_process_progress_writer(environment)
                                    end
          @lifecycle = Lifecycle.start(
            settings: settings,
            watchdog_policy: watchdog_policy,
            operation_liveness_policy: operation_liveness_policy,
            synchronization_graph_policy: synchronization_graph_policy,
            process_progress_policy: process_progress_policy,
            process_progress_writer: process_progress_writer,
            probes_enabled: Environment.probes_enabled?(environment),
            clock: clock,
            session_id_source: session_id_source,
            pid_source: pid_source,
            writer_factory: writer_factory,
            random: random
          )
          # Lifecycle owns the descriptor after a successful start.
          process_progress_writer = nil
          @pid_source = pid_source
          @activation_pid = pid_source.call
          install_shutdown_hook!
          @lifecycle
        rescue StandardError
          process_progress_writer&.close if defined?(process_progress_writer)
          raise if defined?(mode) && mode == :closed

          nil
        end
        # rubocop:enable Metrics/MethodLength

        def current
          return unless @lifecycle

          @lifecycle.ensure_current_process!
          @activation_pid = @pid_source.call
          @lifecycle
        end

        def activated?
          !current.nil?
        end

        def shutdown(exception: nil)
          current&.shutdown(exception: exception)
        end

        private

        def activated_for_current_process?
          return false unless @lifecycle && @pid_source && @activation_pid

          @activation_pid == @pid_source.call
        end

        def install_shutdown_hook!
          return if @shutdown_hook_installed

          at_exit { FiberAudit::Runtime::Boot.shutdown(exception: $ERROR_INFO) }
          @shutdown_hook_installed = true
        end
      end
    end
  end
end

FiberAudit::Runtime::Boot.activate_from_environment! if ENV.key?(FiberAudit::Runtime::Environment::ACTIVATION_KEY)
