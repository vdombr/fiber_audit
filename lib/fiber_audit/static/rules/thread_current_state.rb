# frozen_string_literal: true

require 'fiber_audit/static/rules/base'
require 'fiber_audit/findings/finding'
require 'fiber_audit/findings/evidence'

module FiberAudit
  module Static
    module Rules
      # FA1004: Detects thread-local state usage that may leak across fibers.
      #
      # Matches:
      # - thread_variable_get/set on Thread instances (receiver_constant Thread,
      #   but not direct literal Thread)
      # - Thread.current.[] and Thread.current.[]= (exact syntactic match)
      #
      # Skips:
      # - ActiveSupport::CurrentAttributes (deferred)
      # - Direct Thread class calls (receiver_source == "Thread")
      # - Workspace-shadowed Thread constants
      class ThreadCurrentState < Base
        id 'FA1004'
        severity :high
        confidence :high
        description 'Thread-local state in fiber code may be shared across fibers and leak request-local data'

        TITLE = 'Thread-local state in fiber code'
        CATEGORY = :thread_local
        MESSAGE = 'Thread-local state may be shared across fibers and leak request-local data.'
        REMEDIATION = 'Use fiber-local or framework-provided request-local state instead of Thread thread variables.'

        THREAD_VARIABLE_METHODS = %i[thread_variable_get thread_variable_set].freeze
        INDEX_METHODS = [:[], :[]=].freeze

        def analyze(call_sites:)
          findings = []
          call_sites.each do |cs|
            next if skip?(cs)

            finding = match_thread_variable(cs) || match_index_op(cs)
            findings << finding if finding
          end
          findings
        rescue StandardError
          []
        end

        private

        def skip?(cs)
          defer_current_attributes?(cs) ||
            direct_thread_class?(cs) ||
            workspace_thread_shadowed?(cs)
        end

        def defer_current_attributes?(cs)
          cs.receiver_source.to_s.include?('CurrentAttributes')
        end

        def direct_thread_class?(cs)
          cs.receiver_source == 'Thread'
        end

        def workspace_thread_shadowed?(cs)
          return false unless workspace.respond_to?(:resolve_constant)

          resolved = workspace.resolve_constant('Thread', nesting: cs.nesting)
          return false unless resolved

          workspace_path?(resolved.path)
        rescue StandardError
          false
        end

        def workspace_path?(path)
          return false unless path && workspace.respond_to?(:root)

          path.start_with?(workspace.root.to_s)
        rescue StandardError
          false
        end

        def match_thread_variable(cs)
          return unless THREAD_VARIABLE_METHODS.include?(cs.method_name)

          instance_match = cs.receiver_constant == 'Thread' && cs.receiver_source != 'Thread'
          current_match = cs.receiver_source == 'Thread.current'

          return unless instance_match || current_match

          build_finding(cs, :high, :high, operation(cs))
        end

        def match_index_op(cs)
          return unless INDEX_METHODS.include?(cs.method_name)
          return unless cs.receiver_source == 'Thread.current'

          build_finding(cs, :medium, :high, operation(cs))
        end

        def operation(cs)
          "#{cs.receiver_source}.#{cs.method_name}"
        end

        def build_finding(cs, default_sev, conf, operation)
          context = cs.execution_context
          severity = severity_for(default_sev, context)

          Finding.new(
            rule_id: self.class.id,
            title: TITLE,
            category: CATEGORY,
            severity: severity,
            confidence: conf,
            location: cs.location,
            symbol: cs.enclosing_symbol,
            operation: operation,
            execution_context: context,
            message: MESSAGE,
            evidence: [Evidence.new(source: cs.receiver_source, message: "Thread-local access via #{cs.method_name}")],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
