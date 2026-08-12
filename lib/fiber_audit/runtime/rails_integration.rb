# frozen_string_literal: true

require_relative 'execution_context'

module FiberAudit
  module Runtime
    # Process-local, idempotent Rails integration.
    # Installs prepend hooks for Rails boundaries when detected.
    # Becomes inert after deactivation or fork.
    # Supports late-load rescanning for Rails components loaded after boot.
    class RailsIntegration
      attr_reader :owner_pid, :context_store, :recorder

      def initialize(context_store:, recorder: nil)
        @context_store = context_store
        @recorder = recorder
        @owner_pid = Process.pid
        @active = true
        @middleware_stack = nil
        @require_hook_installed = false
        @mutex = Mutex.new
      end

      def active_for_current_process?
        @active && @owner_pid == Process.pid
      end

      def deactivate!
        @active = false
        self
      end

      def install!
        return unless active_for_current_process?

        @mutex.synchronize do
          install_require_hook
          install_controller_hook
          install_job_hook
          install_cable_hook
          try_install_middleware_hook
        end
        self
      rescue StandardError => e
        handle_installation_failure(e)
        self
      end

      def rescan!
        return unless active_for_current_process?

        @mutex.synchronize do
          install_controller_hook
          install_job_hook
          install_cable_hook
          try_install_middleware_hook
        end
        self
      rescue StandardError => e
        handle_installation_failure(e)
        self
      end

      class << self
        def activate(context_store: ExecutionContext, recorder: nil)
          integration = new(context_store: context_store, recorder: recorder)
          integration.install!
          @current = integration
          @current
        rescue StandardError
          @current = nil
          raise
        end

        attr_reader :current

        def deactivate(integration = nil)
          target = integration || @current
          return unless target

          target.deactivate!
          @current = nil if @current.equal?(target)
        end

        def rescan!
          @current&.rescan! if @current&.active_for_current_process?
        end

        def rescan_after_require!
          key = :fiber_audit_rails_require_rescan
          thread = Thread.current
          acquired = false
          return if thread.thread_variable_get(key)

          thread.thread_variable_set(key, true)
          acquired = true
          rescan!
        ensure
          thread&.thread_variable_set(key, false) if acquired
        end
      end

      private

      def handle_installation_failure(error)
        unless error.instance_variable_defined?(:@fiber_audit_runtime_accounted)
          recorder&.internal_error! unless recorder&.disabled?
          error.instance_variable_set(:@fiber_audit_runtime_accounted, true)
        end
        raise error unless fail_open?
      end

      def fail_open?
        return true unless recorder

        recorder.session.policy.fail_open?
      end

      def account_internal_error
        return unless recorder

        recorder.internal_error! unless recorder.disabled?
      end

      def install_require_hook
        return if @require_hook_installed

        # Zeitwerk replaces Kernel#require. Load its optional integration before
        # prepending FiberAudit so later Rails autoloads retain Zeitwerk's require
        # semantics. This remains a no-op when Zeitwerk is not installed.
        begin
          require 'zeitwerk'
        rescue LoadError
          nil
        end

        # Install narrow guarded require hook for late Rails loading
        # Independent of probe registry
        ::Kernel.prepend(RequireHook) unless ::Kernel.ancestors.include?(RequireHook)
        @require_hook_installed = true
      end

      def install_controller_hook
        namespace = loaded_constant(Object, :ActionController)
        target = loaded_constant(namespace, :Metal)
        return unless target

        target.prepend(ControllerHook) unless target.ancestors.include?(ControllerHook)
      end

      def install_job_hook
        namespace = loaded_constant(Object, :ActiveJob)
        target = loaded_constant(namespace, :Base)
        return unless target

        target.prepend(JobHook) unless target.ancestors.include?(JobHook)
      end

      def install_cable_hook
        namespace = loaded_constant(Object, :ActionCable)
        channel = loaded_constant(namespace, :Channel)
        target = loaded_constant(channel, :Base)
        return unless target

        target.prepend(CableHook) unless target.ancestors.include?(CableHook)
      end

      def loaded_constant(namespace, name)
        return unless namespace.is_a?(Module)
        return if namespace.autoload?(name)
        return unless namespace.const_defined?(name, false)

        namespace.const_get(name, false)
      rescue NameError
        nil
      end

      def try_install_middleware_hook
        rails = loaded_constant(Object, :Rails)
        return unless rails

        # Rails.application may instantiate the application class. Calling it
        # from a require hook while Rails itself is loading can re-enter a
        # partially initialized application, so only inspect an existing instance.
        application = rails.instance_variable_get(:@application)
        return unless application

        stack = application.config.middleware
        return if @middleware_stack.equal?(stack) || middleware_installed_in?(stack)

        # Try to insert middleware into Rails stack. A replacement stack (for
        # example after a Rails reload) is eligible for installation again.
        begin
          stack.insert_before(0, Middleware)
          @middleware_stack = stack
        rescue StandardError => e
          # Stack may be finalized - that's okay, middleware is optional
          handle_installation_failure(e)
        end
      end

      def middleware_installed_in?(stack)
        return false unless stack.respond_to?(:any?)

        stack.any? do |entry|
          entry.equal?(Middleware) || (entry.respond_to?(:klass) && entry.klass.equal?(Middleware))
        end
      end

      # Require hook for late Rails loading - independent of probe registry
      # Narrow, guarded, behavior-preserving
      module RequireHook
        def require(path)
          result = super
          # Only rescan after a successful require that loaded a feature.
          RailsIntegration.rescan_after_require! if result
          result
        end

        private :require
      end

      # Prepend hooks - consult active integration before setting context
      # Resilient to context store failures in fail-open mode
      # Critical: must not catch application exceptions or invoke app twice
      module ControllerHook
        def process_action(...)
          integration = RailsIntegration.current
          return super unless integration&.active_for_current_process?

          executed = false
          begin
            integration.context_store.with(:request) do
              executed = true
              super
            end
          rescue StandardError
            raise if executed
            # Context setup failed before application code ran
            raise unless integration.send(:fail_open?)

            integration.send(:account_internal_error)
            super
          end
        end
      end

      module JobHook
        def perform_now(...)
          integration = RailsIntegration.current
          return super unless integration&.active_for_current_process?

          executed = false
          begin
            integration.context_store.with(:job) do
              executed = true
              super
            end
          rescue StandardError
            raise if executed
            # Context setup failed before application code ran
            raise unless integration.send(:fail_open?)

            integration.send(:account_internal_error)
            super
          end
        end
      end

      module CableHook
        def dispatch_action(...)
          integration = RailsIntegration.current
          return super unless integration&.active_for_current_process?

          executed = false
          begin
            integration.context_store.with(:websocket) do
              executed = true
              super
            end
          rescue StandardError
            raise if executed
            # Context setup failed before application code ran
            raise unless integration.send(:fail_open?)

            integration.send(:account_internal_error)
            super
          end
        end
      end

      # Rack middleware for :middleware context
      class Middleware
        def initialize(app)
          @app = app
        end

        def call(env)
          integration = RailsIntegration.current
          return @app.call(env) unless integration&.active_for_current_process?

          executed = false
          begin
            integration.context_store.with(:middleware) do
              executed = true
              @app.call(env)
            end
          rescue StandardError
            raise if executed
            # Context setup failed before application code ran
            raise unless integration.send(:fail_open?)

            integration.send(:account_internal_error)
            @app.call(env)
          end
        end
      end
    end
  end
end
