# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1006 – Detects direct socket creation that may bypass
      # scheduler-aware networking cooperation. Advisory rule with :low default.
      class DirectSocket < Base
        id 'FA1006'
        severity :low
        default_confidence :high
        description 'Direct socket creation may not cooperate with scheduler-aware networking.'

        TITLE    = 'Direct socket creation'
        CATEGORY = :network

        EXACT = OperationVocabulary::FA1006_EXACT

        MESSAGE = 'Direct socket use may bypass scheduler-aware networking cooperation and stall the scheduler thread.'
        REMEDIATION = 'Use scheduler-aware networking APIs or verify the ' \
                      'socket operations cooperate with the active Fiber scheduler.'

        class << self
          def title = TITLE
          def category = CATEGORY
        end

        def analyze(call_sites:)
          call_sites.filter_map { |site| match(site) }
        end

        private

        def match(site)
          return unless site.method_name == :new

          const = site.receiver_constant
          return unless const

          if EXACT.include?(const)
            return if shadowed?(const, site.nesting)

            return build_finding(site, const)
          end

          return unless ip_socket_subclass?(const)

          build_finding(site, const)
        end

        def shadowed?(name, nesting)
          sem = semantic_index
          return false unless sem

          !sem.resolve_constant(name, nesting: nesting || []).nil?
        rescue StandardError
          false
        end

        def ip_socket_subclass?(name)
          sem = semantic_index
          return false unless sem

          sem.ancestors_of(name).include?('IPSocket')
        rescue StandardError
          false
        end

        def semantic_index
          index = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          index || workspace
        rescue StandardError
          nil
        end

        def build_finding(site, const)
          operation = "#{const}.new"
          ctx = site.execution_context || :unknown

          Finding.new(
            rule_id: self.class.id,
            title: self.class.title,
            category: self.class.category,
            severity: advisory_severity(:low),
            confidence: site.confidence,
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: operation,
            execution_context: ctx,
            message: MESSAGE,
            evidence: [
              Evidence.new(
                source: 'static_analysis',
                message: "Direct socket creation: #{operation}",
                details: { receiver_constant: const, method: :new }
              )
            ],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
