# frozen_string_literal: true

require_relative '../../operation_vocabulary'

module FiberAudit
  module Runtime
    module Probes
      # Hooks and their shared recursion-safe dispatch belong to one probe boundary.
      # rubocop:disable Metrics/ModuleLength
      module Synchronization
        OPERATIONS = OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS
        SUPPRESSION_KEY = :__fiber_audit_synchronization_internal_depth__

        TRY_LOCK_MEASUREMENTS = lambda do |result|
          acquired = result == true
          { acquired: acquired, contention_observed: !acquired }
        end

        module MutexHook
          def lock(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.acquire(self, OPERATIONS.fetch(:mutex_lock)) { super }
          end

          def synchronize(*arguments, **keywords, &application)
            return super unless application
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.synchronize(self, OPERATIONS.fetch(:mutex_synchronize), application) do |wrapped|
              super(*arguments, **keywords, &wrapped)
            end
          end

          def try_lock(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.try_acquire(self, OPERATIONS.fetch(:mutex_try_lock)) { super }
          end

          def unlock(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.release(self, OPERATIONS.fetch(:mutex_unlock)) { super }
          end
        end

        module ConditionVariableHook
          def wait(mutex, ...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.condition_wait(self, mutex, OPERATIONS.fetch(:condition_wait)) { super }
          end

          def signal(...)
            return super if Synchronization.instrumentation_internal?(self)

            Registry.observe(operation: OPERATIONS.fetch(:condition_signal)) { super }
          end

          def broadcast(...)
            return super if Synchronization.instrumentation_internal?(self)

            Registry.observe(operation: OPERATIONS.fetch(:condition_broadcast)) { super }
          end
        end

        module MonitorHook
          def enter(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.acquire(self, OPERATIONS.fetch(:monitor_enter)) { super }
          end

          def synchronize(*arguments, **keywords, &application)
            return super unless application
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.synchronize(self, OPERATIONS.fetch(:monitor_synchronize), application) do |wrapped|
              super(*arguments, **keywords, &wrapped)
            end
          end

          def try_enter(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.try_acquire(self, OPERATIONS.fetch(:monitor_try_enter)) { super }
          end

          def exit(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.release(self, OPERATIONS.fetch(:monitor_exit)) { super }
          end
        end

        module MonitorMixinHook
          def mon_enter(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.with_internal_dispatch do
              Synchronization.acquire(self, OPERATIONS.fetch(:monitor_mixin_enter)) { super }
            end
          end

          def synchronize(*arguments, **keywords, &application)
            return super unless application
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.synchronize(
              self, OPERATIONS.fetch(:monitor_mixin_synchronize), application, internal_dispatch: true
            ) { |wrapped| super(*arguments, **keywords, &wrapped) }
          end

          def mon_try_enter(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.with_internal_dispatch do
              Synchronization.try_acquire(self, OPERATIONS.fetch(:monitor_mixin_try_enter)) { super }
            end
          end

          def mon_exit(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.with_internal_dispatch do
              Synchronization.release(self, OPERATIONS.fetch(:monitor_mixin_exit)) { super }
            end
          end
        end

        module MonitorConditionVariableHook
          def wait(...)
            return super if Synchronization.instrumentation_internal?(self)

            Synchronization.condition_wait(self, nil, OPERATIONS.fetch(:monitor_condition_wait)) { super }
          end

          def signal(...)
            return super if Synchronization.instrumentation_internal?(self)

            Registry.observe(operation: OPERATIONS.fetch(:monitor_condition_signal)) { super }
          end

          def broadcast(...)
            return super if Synchronization.instrumentation_internal?(self)

            Registry.observe(operation: OPERATIONS.fetch(:monitor_condition_broadcast)) { super }
          end
        end

        module_function

        def install!(registry)
          registry.prepend_once(Mutex, MutexHook)
          registry.prepend_once(ConditionVariable, ConditionVariableHook) if defined?(ConditionVariable)
          registry.prepend_once(Monitor, MonitorHook) if defined?(Monitor)
          registry.prepend_once(MonitorMixin, MonitorMixinHook) if defined?(MonitorMixin)
          return unless defined?(MonitorMixin::ConditionVariable)

          registry.prepend_once(MonitorMixin::ConditionVariable, MonitorConditionVariableHook)
        end

        def acquire(resource, operation, &)
          wait = Registry.synchronization_wait(resource: resource, operation: operation)
          completed = false
          result = Registry.observe(operation: operation, &)
          completed = true
          Registry.synchronization_acquired(resource: resource, operation: operation, wait: wait)
          result
        ensure
          Registry.synchronization_wait_completed(wait: wait, operation: operation, acquired: false) if wait && !completed
        end

        def try_acquire(resource, operation, &)
          result = Registry.observe(operation: operation, measurement_builder: TRY_LOCK_MEASUREMENTS, &)
          Registry.synchronization_acquired(resource: resource, operation: operation) if result == true
          result
        end

        def release(resource, operation, &)
          result = Registry.observe(operation: operation, &)
          Registry.synchronization_released(resource: resource, operation: operation)
          result
        end

        def synchronize(resource, operation, application, internal_dispatch: false)
          wait = Registry.synchronization_wait(resource: resource, operation: operation)
          entered = false
          wrapped = proc do |*arguments, **keywords|
            entered = true
            Registry.synchronization_acquired(resource: resource, operation: operation, wait: wait)
            begin
              without_internal_dispatch { invoke(application, arguments, keywords) }
            ensure
              Registry.synchronization_released(resource: resource, operation: operation)
            end
          end
          dispatch = proc { yield wrapped }
          Registry.observe(operation: operation) do
            internal_dispatch ? with_internal_dispatch(&dispatch) : dispatch.call
          end
        ensure
          Registry.synchronization_wait_completed(wait: wait, operation: operation, acquired: false) if wait && !entered
        end

        def condition_wait(condition, owner, operation, &)
          wait = Registry.synchronization_wait(resource: condition, operation: operation)
          owner_was_known = owner && Registry.synchronization_released(resource: owner, operation: operation)
          completed = false
          result = Registry.observe(operation: operation, &)
          completed = true
          result
        ensure
          Registry.synchronization_acquired(resource: owner, operation: operation) if owner_was_known
          Registry.synchronization_wait_completed(wait: wait, operation: operation, acquired: completed) if wait
        end

        def instrumentation_internal?(resource = nil)
          return true if internal_dispatch?
          return false unless resource

          graph = Registry.current&.synchronization_graph
          return false unless graph

          internal_mutexes = [
            graph.instance_variable_get(:@mutex),
            graph.instance_variable_get(:@identities)&.instance_variable_get(:@mutex)
          ]
          internal_mutexes.include?(resource)
        rescue StandardError
          false
        end

        def internal_dispatch?
          Fiber[SUPPRESSION_KEY].to_i.positive?
        rescue StandardError
          false
        end

        def with_internal_dispatch
          depth = Fiber[SUPPRESSION_KEY].to_i
          Fiber[SUPPRESSION_KEY] = depth + 1
          yield
        ensure
          Fiber[SUPPRESSION_KEY] = depth if defined?(depth)
        end

        def without_internal_dispatch
          depth = Fiber[SUPPRESSION_KEY].to_i
          Fiber[SUPPRESSION_KEY] = 0
          yield
        ensure
          Fiber[SUPPRESSION_KEY] = depth if defined?(depth)
        end

        def invoke(application, arguments, keywords)
          keywords.empty? ? application.call(*arguments) : application.call(*arguments, **keywords)
        end
        private_class_method :invoke
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
