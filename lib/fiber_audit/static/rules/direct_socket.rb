# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/finding'
require_relative '../../findings/evidence'

module FiberAudit
  module Static
    module Rules
      # FA1006 – Detects direct socket creation that may bypass
      # scheduler-aware networking and block the scheduler thread.
      class DirectSocket < Base
        id 'FA1006'
        severity :medium
        default_confidence :high
        description 'Detects direct socket creation that may bypass scheduler-aware networking.'

        TITLE    = 'Direct socket creation'
        CATEGORY = :network

        EXACT = %w[
          TCPSocket TCPServer UDPSocket UNIXSocket UNIXServer Socket IPSocket
        ].to_set.freeze

        MESSAGE = 'Direct socket use may bypass scheduler-aware networking ' \
                  'and block the scheduler thread.'
        REMEDIATION = 'Use scheduler-aware networking APIs or verify the ' \
                      'socket operations cooperate with the active Fiber scheduler.'

        class << self
          def title;    TITLE;    end
          def category; CATEGORY; end
        end

        def analyze(call_sites:)
          call_sites.filter_map { |cs| match(cs) }
        end

        private

        def match(cs)
          return unless cs.method_name == :new

          const = cs.receiver_constant
          return unless const

          if EXACT.include?(const)
            return if shadowed?(const, cs.nesting)

            return build_finding(cs, const)
          end

          return unless ip_socket_subclass?(const)

          build_finding(cs, const)
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
          return workspace if workspace.respond_to?(:ancestors_of)

          workspace.semantic_index if workspace.respond_to?(:semantic_index)
        rescue StandardError
          nil
        end

        def build_finding(cs, const)
          operation = "#{const}.new"
          ctx = cs.execution_context || :unknown

          Finding.new(
            rule_id: self.class.id,
            title: self.class.title,
            category: self.class.category,
            severity: severity_for(:medium, ctx),
            confidence: cs.confidence,
            location: cs.location,
            symbol: cs.enclosing_symbol,
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
