# frozen_string_literal: true

module FiberAudit
  module Runtime
    module Probes
      module HTTP
        HTTP_SCHEME = /\Ahttps?:/i
        IPV4_LITERAL = /\A(?:\d{1,3}\.){3}\d{1,3}\z/

        module NetHTTPClassHook
          def get(*arguments, **, &)
            Registry.observe(operation: 'Net::HTTP.get', measurements: HTTP.target_measurements(arguments.first)) { super }
          end

          def get_response(*arguments, **, &)
            Registry.observe(operation: 'Net::HTTP.get_response', measurements: HTTP.target_measurements(arguments.first)) { super }
          end

          def start(*arguments, **, &)
            Registry.observe(operation: 'Net::HTTP.start', measurements: HTTP.host_measurements(arguments.first)) { super }
          end
        end

        module NetHTTPClassRequestHook
          def request(*arguments, **, &)
            Registry.observe(operation: 'Net::HTTP.request', measurements: HTTP.target_measurements(arguments[1])) { super }
          end
        end

        module NetHTTPInstanceHook
          def start(...)
            Registry.observe(operation: 'Net::HTTP.start', measurements: HTTP.connection_measurements(self)) { super }
          end

          def request(...)
            Registry.observe(operation: 'Net::HTTP.request', measurements: HTTP.connection_measurements(self)) { super }
          end
        end

        module URIHook
          def open(*arguments, **, &)
            return super unless HTTP.http_target?(arguments.first)

            Registry.observe(
              operation: 'URI.open',
              measurements: HTTP.target_measurements(arguments.first, parse_string: true)
            ) { super }
          end
        end

        module OpenURIHook
          def open_uri(*arguments, **, &)
            return super unless HTTP.http_target?(arguments.first)

            Registry.observe(
              operation: 'OpenURI.open_uri',
              measurements: HTTP.target_measurements(arguments.first, parse_string: true)
            ) { super }
          end
        end

        module_function

        def install!(registry)
          if defined?(Net::HTTP)
            registry.prepend_once(Net::HTTP.singleton_class, NetHTTPClassHook)
            registry.prepend_once(Net::HTTP, NetHTTPInstanceHook)
            registry.prepend_once(Net::HTTP.singleton_class, NetHTTPClassRequestHook) if Net::HTTP.respond_to?(:request)
          end
          registry.prepend_once(URI.singleton_class, URIHook) if defined?(URI) && URI.respond_to?(:open)
          return unless defined?(OpenURI) && OpenURI.respond_to?(:open_uri)

          registry.prepend_once(OpenURI.singleton_class, OpenURIHook)
        end

        def connection_measurements(http)
          started = Net::HTTP.instance_method(:started?).bind_call(http)
          return { endpoint_resolution_applicable: false }.freeze if started

          address = Net::HTTP.instance_method(:address).bind_call(http)
          host_measurements(address)
        rescue StandardError
          { endpoint_resolution_applicable: nil }.freeze
        end

        def target_measurements(value, parse_string: false)
          host = if defined?(URI::HTTP) && value.is_a?(URI::HTTP)
                   URI::Generic.instance_method(:host).bind_call(value)
                 elsif parse_string && value.instance_of?(String)
                   uri = URI.parse(value)
                   return { endpoint_resolution_applicable: nil }.freeze unless http_target?(uri)

                   URI::Generic.instance_method(:host).bind_call(uri)
                 else
                   value
                 end
          host_measurements(host)
        rescue StandardError
          { endpoint_resolution_applicable: nil }.freeze
        end

        def host_measurements(host)
          { endpoint_resolution_applicable: endpoint_resolution_applicable(host) }.freeze
        end

        def http_target?(value)
          return value.match?(HTTP_SCHEME) if value.instance_of?(String) && value.valid_encoding?
          return false unless defined?(URI::HTTP)

          value.instance_of?(URI::HTTP) || (defined?(URI::HTTPS) && value.instance_of?(URI::HTTPS))
        rescue StandardError
          false
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
      end
    end
  end
end
