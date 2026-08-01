# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/finding'
require_relative '../../findings/evidence'
require_relative '../../findings/location'

module FiberAudit
  module Static
    module Rules
      # FA1007: Detects blocking HTTP calls in request-like contexts.
      #
      # Targets:
      # - Net::HTTP.get, Net::HTTP.get_response, Net::HTTP.start, Net::HTTP.request
      # - URI.open, OpenURI.open_uri
      #
      # Emits findings only for request/middleware/websocket/callback contexts.
      # Skips job/boot/rake/test/unknown contexts.
      #
      # For URI/OpenURI, inspects the first argument:
      # - Skips if it's a simple quoted literal with a non-http(s) scheme
      # - Emits with :medium severity and :low confidence for http/https/unknown args
      class NetHTTPInRequest < Base
        id 'FA1007'
        severity :high
        default_confidence :high
        description 'Blocking HTTP call in request path'

        TITLE = 'Blocking HTTP call in request path'
        CATEGORY = :network

        MESSAGE = 'Synchronous HTTP activity in a request-like context may block the thread running the fiber scheduler.'
        REMEDIATION = 'Use a scheduler-aware HTTP client, or move outbound HTTP work outside the request path.'

        NET_HTTP_METHODS = %i[get get_response start request].freeze
        URI_METHODS = %i[open open_uri].freeze

        EMIT_CONTEXTS = %i[request middleware websocket callback].freeze
        SKIP_CONTEXTS = %i[job boot rake test unknown].freeze

        def analyze(call_sites:)
          findings = []

          call_sites.each do |call_site|
            next unless eligible_context?(call_site)
            next if workspace_shadowed?(call_site)

            finding = analyze_call_site(call_site)
            findings << finding if finding
          end

          findings
        rescue StandardError
          []
        end

        private

        def eligible_context?(call_site)
          ctx = call_site.execution_context
          EMIT_CONTEXTS.include?(ctx)
        end

        def workspace_shadowed?(call_site)
          receiver_const = call_site.receiver_constant
          method_name = call_site.method_name

          return false unless receiver_const && method_name

          # Check if the receiver constant is workspace-defined (shadowed)
          if receiver_const.start_with?('Net::HTTP')
            return !workspace_constant?('Net::HTTP')
          elsif receiver_const.start_with?('URI')
            return !workspace_constant?('URI')
          elsif receiver_const.start_with?('OpenURI')
            return !workspace_constant?('OpenURI')
          end

          false
        rescue StandardError
          false
        end

        def workspace_constant?(const_name)
          return false unless @workspace.respond_to?(:semantic_index)

          semantic_index = @workspace.semantic_index
          return false unless semantic_index.respond_to?(:resolve_constant)

          # If resolve_constant returns non-nil, it's workspace-defined
          semantic_index.resolve_constant(const_name, nesting: []).nil?
        rescue StandardError
          false
        end

        def analyze_call_site(call_site)
          receiver_const = call_site.receiver_constant
          method_name = call_site.method_name

          return nil unless receiver_const && method_name

          if receiver_const == 'Net::HTTP' && NET_HTTP_METHODS.include?(method_name)
            analyze_net_http(call_site)
          elsif (receiver_const == 'URI' || receiver_const == 'OpenURI') && URI_METHODS.include?(method_name)
            analyze_uri_open(call_site)
          end
        end

        def analyze_net_http(call_site)
          context = call_site.execution_context
          final_severity = severity_for(:high, context)

          operation = "Net::HTTP.#{call_site.method_name}"

          evidence = [
            Evidence.new(
              source: 'call_site',
              message: "Blocking HTTP call detected: #{operation}",
              details: {
                receiver: call_site.receiver_constant,
                method: call_site.method_name,
                context: context
              }
            )
          ]

          Finding.new(
            rule_id: self.class.id,
            title: TITLE,
            category: CATEGORY,
            severity: final_severity,
            confidence: :high,
            location: Location.new(
              path: call_site.path,
              line: call_site.line,
              column: call_site.column
            ),
            symbol: call_site.enclosing_symbol,
            operation: operation,
            execution_context: context,
            message: MESSAGE,
            evidence: evidence,
            remediation: REMEDIATION
          )
        end

        def analyze_uri_open(call_site)
          # Inspect first argument for URI/OpenURI
          first_arg = call_site.arguments&.first
          return nil if non_http_literal?(first_arg)

          operation = "#{call_site.receiver_constant}.#{call_site.method_name}"

          evidence = [
            Evidence.new(
              source: 'call_site',
              message: "Blocking HTTP call detected: #{operation}",
              details: {
                receiver: call_site.receiver_constant,
                method: call_site.method_name,
                argument: first_arg,
                context: call_site.execution_context
              }
            )
          ]

          Finding.new(
            rule_id: self.class.id,
            title: TITLE,
            category: CATEGORY,
            severity: :medium,
            confidence: :low,
            location: Location.new(
              path: call_site.path,
              line: call_site.line,
              column: call_site.column
            ),
            symbol: call_site.enclosing_symbol,
            operation: operation,
            execution_context: call_site.execution_context,
            message: MESSAGE,
            evidence: evidence,
            remediation: REMEDIATION
          )
        end

        def non_http_literal?(arg)
          return false unless arg.is_a?(String)

          # Check if it's a quoted string with a non-http(s) scheme
          # Examples: "ftp://...", "file://...", "mailto:..."
          # Skip if it starts with http:// or https://
          return false if arg.match?(%r{\Ahttps?://}i)

          # Check for other schemes
          arg.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
        end
      end
    end
  end
end
