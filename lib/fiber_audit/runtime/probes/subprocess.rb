# frozen_string_literal: true

module FiberAudit
  module Runtime
    module Probes
      module Subprocess
        module KernelInstanceHook
          def system(...)
            Registry.observe(operation: 'Kernel.system') { super }
          end

          def exec(...)
            Registry.observe(operation: 'Kernel.exec', emit_start: true) { super }
          end

          def spawn(...)
            Registry.observe(operation: 'Kernel.spawn') { super }
          end

          private :system, :exec, :spawn
        end

        module KernelSingletonHook
          def system(...)
            Registry.observe(operation: 'Kernel.system') { super }
          end

          def exec(...)
            Registry.observe(operation: 'Kernel.exec', emit_start: true) { super }
          end

          def spawn(...)
            Registry.observe(operation: 'Kernel.spawn') { super }
          end
        end

        module IOHook
          def popen(...)
            Registry.observe(operation: 'IO.popen') { super }
          end
        end

        module ProcessHook
          def waitall(...)
            Registry.observe(operation: 'Process.waitall') { super }
          end

          def detach(...)
            Registry.observe(operation: 'Process.detach') { super }
          end
        end

        module Open3Hook
          def capture2(...)
            Registry.observe(operation: 'Open3.capture2') { super }
          end

          def capture2e(...)
            Registry.observe(operation: 'Open3.capture2e') { super }
          end

          def capture3(...)
            Registry.observe(operation: 'Open3.capture3') { super }
          end

          def pipeline(...)
            Registry.observe(operation: 'Open3.pipeline') { super }
          end
        end

        module_function

        def install!(registry)
          registry.prepend_once(Kernel, KernelInstanceHook)
          registry.prepend_once(Kernel.singleton_class, KernelSingletonHook)
          registry.prepend_once(IO.singleton_class, IOHook)
          registry.prepend_once(Process.singleton_class, ProcessHook)
          registry.prepend_once(Open3.singleton_class, Open3Hook) if defined?(Open3)
        end
      end
    end
  end
end
