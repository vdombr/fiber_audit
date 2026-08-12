# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1005: Detects explicit IO.select calls that may bypass
      # scheduler-aware I/O cooperation. Advisory rule with :medium default.
      class IOSelect < Base
        id 'FA1005'
        severity :medium
        default_confidence :high
        description 'Explicit IO.select bypasses scheduler-aware I/O cooperation'

        TITLE    = 'Explicit IO.select call'
        CATEGORY = :blocking_io

        MESSAGE = 'Explicit IO.select bypasses scheduler-aware I/O cooperation and may stall the scheduler thread.'
        REMEDIATION = 'Use scheduler-aware I/O APIs or allow the active Fiber scheduler to manage readiness.'

        TARGETS = OperationVocabulary::FA1005_TARGETS

        class << self
          def title = TITLE
          def category = CATEGORY
        end

        def analyze(call_sites:)
          call_sites.filter_map { |site| match(site) }
        end

        private

        def match(site)
          return unless site.method_name == :select

          receiver = site.receiver_constant

          if receiver.nil? && site.receiver_source.nil?
            # Bare select() call — treat as Kernel.select with unknown confidence
            return build_finding(site, 'Kernel', :unknown)
          end

          canonical = TARGETS[receiver]
          return unless canonical == :select
          return if shadowed?(receiver, site.nesting)

          build_finding(site, receiver, site.confidence)
        end

        def shadowed?(constant_name, nesting)
          sem = semantic_index
          return false unless sem

          !sem.resolve_constant(constant_name, nesting: nesting || []).nil?
        rescue StandardError
          false
        end

        def semantic_index
          index = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          return index if index

          workspace if workspace.respond_to?(:resolve_constant)
        rescue StandardError
          nil
        end

        def build_finding(site, constant, confidence)
          operation = "#{constant}.select"
          context = site.execution_context || :unknown

          Finding.new(
            rule_id: self.class.id,
            title: TITLE,
            category: CATEGORY,
            severity: advisory_severity(:medium),
            confidence: confidence,
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: operation,
            execution_context: context,
            message: MESSAGE,
            evidence: [
              Evidence.new(
                source: 'static_analysis',
                message: "Explicit IO.select: #{operation}",
                details: { receiver: constant, method: :select }
              )
            ],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
