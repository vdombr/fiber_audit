# frozen_string_literal: true

module FiberAudit
  module Runtime
    module Probes
      module ThreadState
        module Hook
          def thread_variable_get(...)
            Registry.observe(operation: 'Thread.thread_variable_get') { super }
          end

          def thread_variable_set(...)
            Registry.observe(operation: 'Thread.thread_variable_set') { super }
          end

          def [](...)
            return super unless equal?(Thread.current)

            Registry.observe(operation: 'Thread.current.[]') { super }
          end

          def []=(...)
            if equal?(Thread.current)
              Registry.observe(operation: 'Thread.current.[]=') { super }
            else
              super
            end
          end
        end

        module_function

        def install!(registry)
          registry.prepend_once(Thread, Hook)
        end
      end
    end
  end
end
