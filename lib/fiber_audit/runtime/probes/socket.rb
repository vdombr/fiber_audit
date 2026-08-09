# frozen_string_literal: true

require_relative '../../operation_vocabulary'

module FiberAudit
  module Runtime
    module Probes
      module Socket
        MODULE_NAME = Module.instance_method(:name)
        MODULE_COMPARE = Module.instance_method(:<=)
        CONST_DEFINED = Module.instance_method(:const_defined?)
        CONST_GET = Module.instance_method(:const_get)

        module ConstructorHook
          def new(...)
            operation = Socket.operation_for(self)
            return super unless operation

            Registry.observe(operation: operation) { super }
          end
        end

        module_function

        def install!(registry)
          return unless defined?(::BasicSocket)

          registry.prepend_once(::BasicSocket.singleton_class, ConstructorHook)
        end

        def operation_for(klass)
          name = MODULE_NAME.bind_call(klass)
          return unless safe_constant_name?(name)
          return unless exact_socket?(klass, name) || ip_socket_subclass?(klass)
          return unless resolve_constant(name).equal?(klass)

          "#{name}.new"
        rescue StandardError
          nil
        end

        def exact_socket?(klass, name)
          return false unless OperationVocabulary::FA1006_EXACT.include?(name)

          resolve_constant(name).equal?(klass)
        end

        def ip_socket_subclass?(klass)
          return false unless defined?(::IPSocket)

          MODULE_COMPARE.bind_call(klass, ::IPSocket) == true
        end

        def safe_constant_name?(name)
          name.is_a?(String) && name.bytesize <= 240 &&
            name.match?(/\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/)
        end

        def resolve_constant(name)
          namespace = Object
          name.split('::').each do |part|
            unless CONST_DEFINED.bind_call(namespace, part, false)
              namespace = nil
              break
            end

            namespace = CONST_GET.bind_call(namespace, part, false)
          end
          namespace
        rescue NameError, TypeError
          nil
        end
      end
    end
  end
end
