# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'

module FiberAudit
  module Static
    module Rules
      class BlockingSubprocess < Base
        id 'FA1001'
        severity :high
        default_confidence :high
        description 'Blocking subprocess call in the fiber scheduler path'

        TARGETS = {
          'Kernel' => %i[system exec spawn].freeze,
          'Open3' => %i[capture2 capture2e capture3 pipeline].freeze,
          'IO' => %i[popen].freeze,
          'Process' => %i[waitall detach].freeze
        }.freeze

        BARE_KERNEL_METHODS = %i[system exec spawn].freeze

        MESSAGE = 'Subprocess operation may block the thread running the fiber scheduler.'
        REMEDIATION = 'Move long-running subprocess work outside the request path, or verify scheduler behaviour under load.'

        def analyze(call_sites:)
          call_sites.filter_map do |site|
            next unless (match = match_call_site(site))

            build_finding(site, match)
          end
        end

        private

        def match_call_site(site)
          receiver = site.receiver_constant
          method = site.method_name

          if receiver.nil? && site.receiver_source.nil? && BARE_KERNEL_METHODS.include?(method)
            return { constant: 'Kernel', method: method, confidence: :unknown }
          end

          return nil unless receiver && TARGETS.key?(receiver)
          return nil unless TARGETS[receiver].include?(method)
          return nil if shadowed?(receiver, site.nesting)

          { constant: receiver, method: method, confidence: site.confidence }
        end

        def shadowed?(constant_name, nesting)
          sem = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          sem ||= workspace if workspace.respond_to?(:resolve_constant)
          return false unless sem.respond_to?(:resolve_constant)

          resolved = sem.resolve_constant(constant_name, nesting: nesting || [])
          !resolved.nil?
        rescue StandardError
          false
        end

        def build_finding(site, match)
          operation = "#{match[:constant]}.#{match[:method]}"
          context = site.execution_context || :unknown
          sev = severity_for(self.class.severity, context)

          Finding.new(
            rule_id: self.class.id,
            title: 'Blocking subprocess call',
            category: :subprocess,
            severity: sev,
            confidence: match[:confidence],
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: operation,
            execution_context: context,
            message: MESSAGE,
            evidence: [
              Evidence.new(
                source: :static,
                message: "Matched #{operation}",
                details: { receiver: match[:constant], method: match[:method] }
              )
            ],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
