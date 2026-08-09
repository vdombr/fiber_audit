# frozen_string_literal: true

module FiberAudit
  module Runtime
    module Probes
      module ThreadWait
        module Hook
          def join(...)
            Registry.observe(operation: 'Thread.join') { super }
          end

          def value(...)
            Registry.observe(operation: 'Thread.value') { super }
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
