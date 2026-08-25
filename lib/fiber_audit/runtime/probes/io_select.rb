# frozen_string_literal: true

module FiberAudit
  module Runtime
    module Probes
      module IOSelect
        module_function

        def timeout_measurements(arguments)
          timeout = arguments[3] if arguments.length >= 4
          { timeout_present: !timeout.nil?, timeout_zero: timeout_zero(timeout) }
        rescue StandardError
          { timeout_present: nil, timeout_zero: nil }
        end

        def timeout_zero(value)
          return false if value.nil?
          return value.zero? if value.instance_of?(Integer) || value.instance_of?(Float)
          return value.zero? if defined?(Rational) && value.instance_of?(Rational)

          nil
        rescue StandardError
          nil
        end
        private_class_method :timeout_zero

        module IOHook
          def select(*arguments, &)
            Registry.observe(operation: 'IO.select', measurements: IOSelect.timeout_measurements(arguments)) { super }
          end
        end

        module KernelInstanceHook
          def select(*arguments, &)
            Registry.observe(operation: 'Kernel.select', measurements: IOSelect.timeout_measurements(arguments)) { super }
          end

          private :select
        end

        module KernelSingletonHook
          def select(*arguments, &)
            Registry.observe(operation: 'Kernel.select', measurements: IOSelect.timeout_measurements(arguments)) { super }
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
