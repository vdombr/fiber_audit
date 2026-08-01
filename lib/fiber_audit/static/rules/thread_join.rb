# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/location'
require_relative '../../findings/evidence'
require_relative '../../findings/finding'

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
      class ThreadJoin < Base
        id 'FA1002'
        severity :high
        confidence :high
        description 'Waiting for a thread may block the thread running the fiber scheduler.'

        TITLE    = 'Thread wait'
        CATEGORY = :synchronization
        MESSAGE  = 'Waiting for a thread may block the thread running the fiber scheduler.'
        REMEDIATION = 'Replace thread waits with scheduler-aware coordination, ' \
                      'or move the work outside the fiber-scheduled path.'
        TARGET_METHODS  = %i[join value].freeze
        CANONICAL_OPS   = %w[Thread.join Thread.value].freeze
        SKIP_SOURCES    = %w[Thread worker].freeze

        def analyze(call_sites:)
          call_sites.filter_map { |cs| match(cs) }
        end

        private

        def match(cs)
          return unless TARGET_METHODS.include?(cs.method_name)
          return unless thread_instance?(cs)
          return if shadowed_thread?(cs)

          build_finding(cs)
        end

        # Receiver must resolve to Thread but not be the bare literal.
        def thread_instance?(cs)
          !SKIP_SOURCES.include?(cs.receiver_source) &&
            cs.receiver_constant == 'Thread'
        rescue StandardError
          false
        end

        # Check workspace / semantic_index resolve_constant seam.
        # Adapter errors are swallowed.
        def shadowed_thread?(cs)
          return false unless workspace

          if workspace.respond_to?(:resolve_constant)
            r = workspace.resolve_constant('Thread')
            return true if r && r != 'Thread'
          end

          return false unless workspace.respond_to?(:semantic_index)

          idx = workspace.semantic_index
          return false unless idx&.respond_to?(:resolve_constant)

          r = idx.resolve_constant('Thread')
          r && r != 'Thread'
        rescue StandardError
          false
        end

        def build_finding(cs)
          loc  = Location.new(path: cs.path, line: cs.line, column: cs.column)
          op   = "Thread.#{cs.method_name}"
          sev  = severity_for(self.class.severity, cs.execution_context)
          conf = cs.receiver_source == 'Thread.current' ? :high : self.class.confidence

          Finding.new(
            rule_id: self.class.id, title: TITLE, category: CATEGORY,
            severity: sev, confidence: conf, location: loc,
            symbol: cs.enclosing_symbol, operation: op,
            execution_context: cs.execution_context,
            message: MESSAGE,
            evidence: [Evidence.new(
              source: 'static_analysis',
              message: "#{op} on #{cs.receiver_source}",
              details: { operation: op, receiver: cs.receiver_source,
                         canonical_operations: CANONICAL_OPS }
            )],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
