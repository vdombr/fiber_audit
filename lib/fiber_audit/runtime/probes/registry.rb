# frozen_string_literal: true

require_relative 'base'
require_relative 'http'
require_relative 'io_select'
require_relative 'socket'
require_relative 'subprocess'
require_relative 'synchronization'
require_relative 'thread_state'
require_relative 'thread_wait'

module FiberAudit
  module Runtime
    module Probes
      # Process-local owner of idempotent probe installation and dispatch.
      class Registry
        PROBE_INSTALLERS = [
          Subprocess,
          ThreadWait,
          Synchronization,
          ThreadState,
          IOSelect,
          Socket,
          HTTP
        ].freeze

        module RequireInstanceHook
          def require(...)
            result = super
            Registry.rescan_current!
            result
          end

          private :require
        end

        module RequireSingletonHook
          def require(...)
            result = super
            Registry.rescan_current!
            result
          end
        end

        class << self
          def activate(base:)
            raise RuntimeContractError, 'base must be a Runtime::Probes::Base' unless base.is_a?(Base)

            registry = new(base: base)
            @current = registry
            registry.install!
            registry
          rescue StandardError
            registry&.deactivate
            @current = nil if @current.equal?(registry)
            raise
          end

          def observe(operation:, measurements: {}, emit_start: false, measurement_builder: nil, &application)
            raise ArgumentError, 'probe observation requires a block' unless application

            registry = current_for_observation
            return application.call unless registry

            registry.base.observe(
              operation: operation,
              measurements: measurements,
              emit_start: emit_start,
              measurement_builder: measurement_builder,
              &application
            )
          end

          def rescan_current!
            current_for_observation&.scan!
          end

          def deactivate(registry)
            @current = nil if @current.equal?(registry)
            registry&.deactivate
          end

          def current
            current_for_observation
          end

          private

          def current_for_observation
            registry = @current
            return unless registry
            return registry if registry.active_for_current_process?
            return unless registry.stale_process?

            FiberAudit::Runtime::Boot.current if defined?(FiberAudit::Runtime::Boot)
            registry = @current
            registry if registry&.active_for_current_process?
          end
        end

        attr_reader :base, :owner_pid

        def initialize(base:)
          @base = base
          @owner_pid = Process.pid
          @mutex = Mutex.new
          @active = true
        end

        def install!
          scan!
          self
        end

        def scan!
          return self unless active_for_current_process?

          base.with_guard do
            @mutex.synchronize do
              prepend_once(Kernel, RequireInstanceHook)
              prepend_once(Kernel.singleton_class, RequireSingletonHook)
              PROBE_INSTALLERS.each { |installer| installer.install!(self) }
            end
          end
          self
        rescue StandardError => e
          base.instrumentation_failure(e)
          self
        end

        def prepend_once(target, hook)
          unless target.is_a?(Module) && hook.is_a?(Module)
            raise RuntimeContractError, 'probe target and hook must be Modules'
          end

          target.prepend(hook) unless target.ancestors.include?(hook)
          target
        end

        def deactivate
          @active = false
          base.deactivate
          self
        end

        def active_for_current_process?
          @active && owner_pid == Process.pid
        end

        def stale_process?
          owner_pid != Process.pid
        end
      end
    end
  end
end
