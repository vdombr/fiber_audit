# frozen_string_literal: true

module FiberAudit
  module Runtime
    module Probes
      module IOSelect
        module_function

        def timeout_measurement(arguments)
          { timeout_present: arguments.length >= 4 && !arguments[3].nil? }
        end

        module IOHook
          def select(*arguments, &)
            Registry.observe(
              operation: 'IO.select',
              measurements: IOSelect.timeout_measurement(arguments)
            ) { super }
          end
        end

        module KernelInstanceHook
          def select(*arguments, &)
            Registry.observe(
              operation: 'Kernel.select',
              measurements: IOSelect.timeout_measurement(arguments)
            ) { super }
          end

          private :select
        end

        module KernelSingletonHook
          def select(*arguments, &)
            Registry.observe(
              operation: 'Kernel.select',
              measurements: IOSelect.timeout_measurement(arguments)
            ) { super }
          end
        end

        def install!(registry)
          registry.prepend_once(IO.singleton_class, IOHook)
          registry.prepend_once(Kernel, KernelInstanceHook)
          registry.prepend_once(Kernel.singleton_class, KernelSingletonHook)
        end
      end
    end
  end
end
