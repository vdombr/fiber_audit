# frozen_string_literal: true

require_relative 'base'
require_relative 'fiber_context'
require_relative 'http'
require_relative 'io_select'
require_relative 'socket'
require_relative 'subprocess'
require_relative 'synchronization'
require_relative '../synchronization_graph'
require_relative 'thread_state'
require_relative 'thread_wait'

module FiberAudit
  module Runtime
    module Probes
      # Process-local owner of idempotent probe installation and dispatch.
      class Registry
        PROBE_INSTALLERS = [
          FiberContext,
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
          def activate(base:, synchronization_graph: nil)
            raise RuntimeContractError, 'base must be a Runtime::Probes::Base' unless base.is_a?(Base)
            unless synchronization_graph.nil? || synchronization_graph.is_a?(SynchronizationGraph)
              raise RuntimeContractError,
                    'synchronization_graph must be a Runtime::SynchronizationGraph or nil'
            end

            registry = new(base: base, synchronization_graph: synchronization_graph)
            @current = registry
            registry.install!
            registry
          rescue StandardError
            registry&.deactivate
            @current = nil if @current.equal?(registry)
            raise
          end

          def with_fiber_mode(kind)
            raise ArgumentError, 'Fiber mode context requires a block' unless block_given?

            registry = current_for_observation
            return yield unless registry

            application_started = false
            begin
              FiberModeContext.with(kind) do
                application_started = true
                yield
              end
            rescue StandardError => e
              raise if application_started

              registry.base.instrumentation_failure(e)
              yield
            end
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

          def synchronization_wait(resource:, operation:)
            dispatch_graph(:begin_wait, resource: resource, operation: operation)
          end

          def synchronization_acquired(resource:, operation:, wait: nil)
            dispatch_graph(:acquired, resource: resource, operation: operation, wait: wait)
          end

          def synchronization_wait_completed(wait:, operation:, acquired: false)
            dispatch_graph(:wait_completed, wait: wait, operation: operation, acquired: acquired)
          end

          def synchronization_released(resource:, operation:)
            dispatch_graph(:released, resource: resource, operation: operation)
          end

          private

          def dispatch_graph(method_name, **arguments)
            registry = current_for_observation
            graph = registry&.synchronization_graph
            return unless graph&.active?

            Synchronization.with_internal_dispatch do
              registry.base.with_guard { graph.public_send(method_name, **arguments) }
            end
          end

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

        attr_reader :base, :owner_pid, :synchronization_graph

        def initialize(base:, synchronization_graph: nil)
          @base = base
          @synchronization_graph = synchronization_graph
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
