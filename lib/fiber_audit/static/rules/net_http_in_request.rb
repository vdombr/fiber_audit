# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1007: Detects HTTP scheduler-cooperation requirements in request-like contexts.
      # Targets Net::HTTP.{get,get_response,start,request}, URI.open, OpenURI.open_uri.
      # Excludes Net::HTTP.get_print. Emits only for request/middleware/websocket/callback.
      #
      # Advisory rule with :medium default, no context ceiling.
      class NetHTTPInRequest < Base
        id 'FA1007'
        severity :medium
        default_confidence :high
        description 'HTTP calls require scheduler-aware DNS, socket, and TLS cooperation in request contexts'

        TITLE = 'HTTP scheduler-cooperation requirement'
        CATEGORY = :network
        MESSAGE = 'HTTP activity requires scheduler-aware DNS and I/O cooperation in a non-blocking Fiber.'
        REMEDIATION = 'Verify the selected HTTP/TLS/DNS stack and active scheduler ' \
                      'under load; investigate correlated stalls.'

        NET_HTTP_METHODS = OperationVocabulary::FA1007_NET_HTTP_METHODS
        URI_METHODS = OperationVocabulary::FA1007_URI_METHODS
        EMIT_CONTEXTS = %i[request middleware websocket callback].freeze

        def analyze(call_sites:)
          call_sites.filter_map { |site| analyze_call_site(site) }
        rescue StandardError
          []
        end

        private

        def analyze_call_site(site)
          return unless eligible_context?(site) && (match = match_call_site(site))

          build_finding(site, match)
        end

        def eligible_context?(site)
          EMIT_CONTEXTS.include?(site.execution_context)
        end

        def match_call_site(site)
          receiver = site.receiver_constant
          method = site.method_name
          return unless receiver && method

          if receiver == 'Net::HTTP' && NET_HTTP_METHODS.include?(method)
            return if shadowed?(receiver, site.nesting)

            { type: :net_http, operation: "Net::HTTP.#{method}" }
          elsif URI_METHODS[receiver] == method
            return if shadowed?(receiver, site.nesting) || non_http_literal?(site.arguments&.first)

            { type: :uri, operation: "#{receiver}.#{method}" }
          end
        end

        def shadowed?(const_name, nesting)
          index = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          index ||= workspace if workspace.respond_to?(:resolve_constant)
          return false unless index.respond_to?(:resolve_constant)

          !index.resolve_constant(const_name, nesting: nesting || []).nil?
        rescue StandardError
          false
        end

        def non_http_literal?(argument)
          match = argument&.match(/\A(["'])(.*)\1\z/m)
          return false unless match

          scheme = match[2][/\A([a-z][a-z0-9+.-]*):/i, 1]
          scheme && !%w[http https].include?(scheme.downcase)
        end

        def build_finding(site, match)
          context = site.execution_context
          sev, conf = if match[:type] == :net_http
                        [advisory_severity(:medium), site.confidence]
                      else
                        %i[medium low]
                      end

          FiberAudit::Finding.new(
            rule_id: self.class.id,
            title: TITLE,
            category: CATEGORY,
            severity: sev,
            confidence: conf,
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: match[:operation],
            execution_context: context,
            message: MESSAGE,
            evidence: [
              FiberAudit::Evidence.new(
                source: 'static_analysis',
                message: "HTTP scheduler-cooperation point: #{match[:operation]}",
                details: { receiver: site.receiver_constant, method: site.method_name, context: context }
              )
            ],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
