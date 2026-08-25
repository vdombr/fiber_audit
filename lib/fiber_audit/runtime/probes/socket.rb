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
        IPV4_LITERAL = /\A(?:\d{1,3}\.){3}\d{1,3}\z/

        module ConstructorHook
          def new(*arguments, **, &)
            operation = Socket.operation_for(self)
            return super unless operation

            Registry.observe(
              operation: operation,
              measurements: Socket.endpoint_measurements(operation, arguments)
            ) { super }
          end
        end

        module_function

        def install!(registry)
          return unless defined?(::BasicSocket)

          registry.prepend_once(::BasicSocket.singleton_class, ConstructorHook)
        end

        def endpoint_measurements(operation, arguments)
          applicable = case operation
                       when 'TCPSocket.new' then endpoint_resolution_applicable(arguments.first)
                       when 'TCPServer.new'
                         arguments.length >= 2 ? endpoint_resolution_applicable(arguments.first) : false
                       else return {}.freeze
                       end
          { endpoint_resolution_applicable: applicable }.freeze
        rescue StandardError
          { endpoint_resolution_applicable: nil }.freeze
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

        def endpoint_resolution_applicable(value)
          return false if value.nil?
          return nil unless value.instance_of?(String)
          return nil unless value.valid_encoding? && value.bytesize.between?(1, 255)
          return false if ipv4_literal?(value) || value.match?(/\A\d+\z/)
          return nil if value.include?(':')

          true
        rescue StandardError
          nil
        end
        private_class_method :endpoint_resolution_applicable

        def ipv4_literal?(value)
          value.match?(IPV4_LITERAL) && value.split('.').all? { |part| part.to_i <= 255 }
        end
        private_class_method :ipv4_literal?

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
