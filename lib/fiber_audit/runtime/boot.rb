# frozen_string_literal: true

require 'English'
require_relative 'environment'
require_relative 'lifecycle'

module FiberAudit
  module Runtime
    module Boot
      class << self
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
          @lifecycle = Lifecycle.start(
            settings: settings,
            clock: clock,
            session_id_source: session_id_source,
            pid_source: pid_source,
            writer_factory: writer_factory,
            random: random
          )
          @pid_source = pid_source
          @activation_pid = pid_source.call
          install_shutdown_hook!
          @lifecycle
        rescue StandardError
          raise if defined?(mode) && mode == :closed

          nil
        end

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
