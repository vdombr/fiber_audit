# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1002: Thread#join / Thread#value may block the fiber-scheduler thread.
      #
      # Matches join/value on Thread instances whose receiver_constant is
      # 'Thread' but whose receiver_source is not the bare literal 'Thread'.
      # Covers direct constructor chains (Thread.new.join), assigned receivers
      # (t = Thread.new; t.join), and the exact syntactic Thread.current form.
      #
      # Skips direct Thread.join/value, arbitrary worker.join, wrong methods,
      # and workspace-shadowed Thread (checked via workspace or
      # workspace.semantic_index resolve_constant seam). Adapter errors from
      # those seams are swallowed — they never raise.
      #
      # Advisory rule: uses advisory_severity (no context ceiling), default :low.
      class ThreadJoin < Base
        id 'FA1002'
        severity :low
        confidence :high
        description 'Thread waits do not cooperate with the fiber scheduler'

        TITLE    = 'Thread wait'
        CATEGORY = :synchronization
        MESSAGE  = 'Thread#join/value bypasses fiber scheduler cooperation and may stall the scheduler thread.'
        REMEDIATION = 'Replace thread waits with scheduler-aware coordination, ' \
                      'or move the work outside the fiber-scheduled path.'
        TARGET_METHODS  = OperationVocabulary::FA1002_METHODS
        CANONICAL_OPS   = OperationVocabulary::FA1002_OPERATIONS
        DIRECT_CLASS_SOURCE = 'Thread'

        def analyze(call_sites:)
          call_sites.filter_map { |site| match(site) }
        end

        private

        def match(site)
          return unless TARGET_METHODS.include?(site.method_name)
          return unless thread_instance?(site)
          return if shadowed_thread?(site)

          build_finding(site)
        end

        # Receiver must resolve to Thread but not be the bare literal.
        def thread_instance?(site)
          return true if site.receiver_source == 'Thread.current'

          site.receiver_constant == 'Thread' && site.receiver_source != DIRECT_CLASS_SOURCE
        rescue StandardError
          false
        end

        # Check workspace / semantic_index resolve_constant seam.
        # Adapter errors are swallowed.
        def shadowed_thread?(site)
          index = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          index ||= workspace if workspace.respond_to?(:resolve_constant)
          return false unless index.respond_to?(:resolve_constant)

          !index.resolve_constant('Thread', nesting: site.nesting || []).nil?
        rescue StandardError
          false
        end

        def build_finding(site)
          loc  = site.location
          op   = "Thread.#{site.method_name}"
          sev  = advisory_severity(self.class.severity)
          conf = site.receiver_source == 'Thread.current' ? :high : site.confidence

          Finding.new(
            rule_id: self.class.id, title: TITLE, category: CATEGORY,
            severity: sev, confidence: conf, location: loc,
            symbol: site.enclosing_symbol, operation: op,
            execution_context: site.execution_context,
            message: MESSAGE,
            evidence: [Evidence.new(
              source: 'static_analysis',
              message: "#{op} on #{site.receiver_source}",
              details: { operation: op, receiver: site.receiver_source,
                         canonical_operations: CANONICAL_OPS }
            )],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
