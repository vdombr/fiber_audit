# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1005: Detects explicit IO.select scheduler-capability requirements.
      # Advisory rule with :medium default.
      class IOSelect < Base
        id 'FA1005'
        severity :medium
        default_confidence :high
        description 'Explicit IO.select requires scheduler io_select cooperation'

        TITLE    = 'Explicit IO.select call'
        CATEGORY = :blocking_io

        MESSAGE = 'IO.select requires scheduler io_select support when used from a non-blocking Fiber.'
        REMEDIATION = 'Verify the selected scheduler implements io_select and confirm runtime progress under load.'

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
