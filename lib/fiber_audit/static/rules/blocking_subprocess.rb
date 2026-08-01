# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/finding'
require_relative '../../findings/evidence'

module FiberAudit
  module Static
    module Rules
      class BlockingSubprocess < Base
        id 'FA1001'
        severity :high
        default_confidence :high
        description 'Blocking subprocess call in the fiber scheduler path'

        TARGETS = {
          'Kernel'  => %i[system exec spawn].freeze,
          'Open3'   => %i[capture2 capture2e capture3 pipeline].freeze,
          'IO'      => %i[popen].freeze,
          'Process' => %i[waitall detach].freeze
        }.freeze

        BARE_KERNEL_METHODS = %i[system exec spawn].freeze

        MESSAGE = 'Subprocess operation may block the thread running the fiber scheduler.'
        REMEDIATION = 'Move long-running subprocess work outside the request path, or verify scheduler behaviour under load.'

        def analyze(call_sites:)
          call_sites.filter_map do |cs|
            next unless (match = match_call_site(cs))

            build_finding(cs, match)
          end
        end

        private

        def match_call_site(cs)
          receiver = cs.receiver_constant
          method = cs.method_name

          if receiver.nil? && BARE_KERNEL_METHODS.include?(method)
            return { constant: 'Kernel', method: method, confidence: :unknown }
          end

          return nil unless receiver && TARGETS.key?(receiver)
          return nil unless TARGETS[receiver].include?(method)
          return nil if shadowed?(receiver, cs.nesting)

          { constant: receiver, method: method, confidence: cs.confidence }
        end

        def shadowed?(constant_name, nesting)
          return false unless workspace.respond_to?(:semantic_index)

          sem = workspace.semantic_index
          return false unless sem

          resolved = sem.resolve_constant(constant_name, nesting: nesting || [])
          !resolved.nil?
        rescue StandardError
          false
        end

        def build_finding(cs, match)
          operation = "#{match[:constant]}.#{match[:method]}"
          context = cs.execution_context || :unknown
          sev = severity_for(self.class.severity, context)

          Finding.new(
            rule_id: self.class.id,
            title: 'Blocking subprocess call',
            category: :subprocess,
            severity: sev,
            confidence: match[:confidence],
            location: cs.location,
            symbol: cs.enclosing_symbol,
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
