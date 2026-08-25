# frozen_string_literal: true

require_relative '../../operation_vocabulary'
require_relative '../fiber_mode_context'

module FiberAudit
  module Runtime
    module Probes
      # Narrow wrappers that preserve the source of explicit blocking mode.
      module FiberContext
        module SingletonHook
          def new(*arguments, **keywords, &application)
            return super unless application && FiberContext.explicit_blocking?(keywords)

            wrapped = FiberContext.send(:wrap_block, :fiber_new, application)
            Registry.observe(operation: FiberContext.operation(:fiber_new)) do
              super(*arguments, **keywords, &wrapped)
            end
          end

          def blocking(*arguments, **keywords, &application)
            return super unless application

            wrapped = FiberContext.send(:wrap_block, :fiber_blocking, application)
            Registry.observe(operation: FiberContext.operation(:fiber_blocking)) do
              super(*arguments, **keywords, &wrapped)
            end
          end
        end

        module_function

        def install!(registry)
          registry.prepend_once(::Fiber.singleton_class, SingletonHook)
        end

        def explicit_blocking?(keywords)
          keywords.key?(:blocking) && keywords[:blocking].equal?(true)
        rescue StandardError
          false
        end

        def operation(kind)
          OperationVocabulary::FA1008_OPERATIONS.fetch(kind)
        end

        def wrap_block(kind, application)
          proc do |*arguments, **keywords|
            Registry.with_fiber_mode(kind) do
              if keywords.empty?
                application.call(*arguments)
              else
                application.call(*arguments, **keywords)
              end
            end
          end
        end
        private_class_method :wrap_block
      end
    end
  end
end
