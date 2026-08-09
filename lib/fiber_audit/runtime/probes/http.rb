# frozen_string_literal: true

module FiberAudit
  module Runtime
    module Probes
      module HTTP
        HTTP_SCHEME = /\Ahttps?:/i

        module NetHTTPClassHook
          def get(...)
            Registry.observe(operation: 'Net::HTTP.get') { super }
          end

          def get_response(...)
            Registry.observe(operation: 'Net::HTTP.get_response') { super }
          end

          def start(...)
            Registry.observe(operation: 'Net::HTTP.start') { super }
          end
        end

        module NetHTTPClassRequestHook
          def request(...)
            Registry.observe(operation: 'Net::HTTP.request') { super }
          end
        end

        module NetHTTPInstanceHook
          def start(...)
            Registry.observe(operation: 'Net::HTTP.start') { super }
          end

          def request(...)
            Registry.observe(operation: 'Net::HTTP.request') { super }
          end
        end

        module URIHook
          def open(*arguments, **, &)
            return super unless HTTP.http_target?(arguments.first)

            Registry.observe(operation: 'URI.open') { super }
          end
        end

        module OpenURIHook
          def open_uri(*arguments, **, &)
            return super unless HTTP.http_target?(arguments.first)

            Registry.observe(operation: 'OpenURI.open_uri') { super }
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

        def http_target?(value)
          return value.match?(HTTP_SCHEME) if value.instance_of?(String) && value.valid_encoding?
          return false unless defined?(URI::HTTP)

          value.instance_of?(URI::HTTP) || (defined?(URI::HTTPS) && value.instance_of?(URI::HTTPS))
        rescue StandardError
          false
        end
      end
    end
  end
end
