# frozen_string_literal: true

module FiberAudit
  module Runtime
    module Probes
      module Synchronization
        TRY_LOCK_MEASUREMENTS = lambda do |result|
          acquired = result == true
          { acquired: acquired, contention_observed: !acquired }
        end

        module MutexHook
          def lock(...)
            Registry.observe(operation: 'Mutex#lock') { super }
          end

          def synchronize(...)
            Registry.observe(operation: 'Mutex#synchronize') { super }
          end

          def try_lock(...)
            Registry.observe(
              operation: 'Mutex#try_lock',
              measurement_builder: TRY_LOCK_MEASUREMENTS
            ) { super }
          end
        end

        module ConditionVariableHook
          def wait(...)
            Registry.observe(operation: 'ConditionVariable#wait') { super }
          end
        end

        module MonitorHook
          def synchronize(...)
            Registry.observe(operation: 'Monitor#synchronize') { super }
          end
        end

        module MonitorMixinHook
          def synchronize(...)
            Registry.observe(operation: 'MonitorMixin#synchronize') { super }
          end
        end

        module_function

        def install!(registry)
          registry.prepend_once(Mutex, MutexHook)
          registry.prepend_once(ConditionVariable, ConditionVariableHook) if defined?(ConditionVariable)
          registry.prepend_once(Monitor, MonitorHook) if defined?(Monitor)
          registry.prepend_once(MonitorMixin, MonitorMixinHook) if defined?(MonitorMixin)
        end
      end
    end
  end
end
