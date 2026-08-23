# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1004: Detect thread-variable state access without inferring stored data.
      class ThreadCurrentState < Base
        id 'FA1004'
        severity :medium
        confidence :high
        description 'Thread-variable access may share mutable state across fibers on one thread'

        TITLE = 'Thread-variable access shared across fibers'
        CATEGORY = :thread_local
        MESSAGE = 'Thread variables are visible to fibers sharing a thread. This access may expose mutable ' \
                  'state across concurrent work, but static analysis does not establish request-sensitive leakage.'
        REMEDIATION = 'Prefer fiber-local storage (Fiber[:key]) or framework-provided ' \
                      'request-local state over thread_variable_get/set.'

        THREAD_VARIABLE_METHODS = OperationVocabulary::FA1004_THREAD_VARIABLE_METHODS

        def analyze(call_sites:)
          findings = []
          call_sites.each do |site|
            next if skip?(site)

            finding = match_thread_variable(site)
            findings << finding if finding
          end
          findings
        rescue StandardError
          []
        end

        private

        def skip?(site)
          defer_current_attributes?(site) ||
            direct_thread_class?(site) ||
            workspace_thread_shadowed?(site)
        end

        def defer_current_attributes?(site)
          site.receiver_source.to_s.include?('CurrentAttributes')
        end

        def direct_thread_class?(site)
          site.receiver_source == 'Thread'
        end

        def workspace_thread_shadowed?(site)
          index = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          index ||= workspace if workspace.respond_to?(:resolve_constant)
          return false unless index.respond_to?(:resolve_constant)

          !index.resolve_constant('Thread', nesting: site.nesting || []).nil?
        rescue StandardError
          false
        end

        def match_thread_variable(site)
          return unless THREAD_VARIABLE_METHODS.include?(site.method_name)

          instance_match = site.receiver_constant == 'Thread' && site.receiver_source != 'Thread'
          current_match = site.receiver_source == 'Thread.current'
          return unless instance_match || current_match

          build_finding(site, operation(site))
        end

        def operation(site)
          "Thread.#{site.method_name}"
        end

        def build_finding(site, operation)
          Finding.new(
            rule_id: self.class.id,
            title: TITLE,
            category: CATEGORY,
            severity: advisory_severity(:medium),
            confidence: :high,
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: operation,
            execution_context: site.execution_context,
            message: MESSAGE,
            evidence: [Evidence.new(
              source: site.receiver_source,
              message: "Matched thread-variable access via #{site.method_name}",
              details: { operation: operation, receiver: site.receiver_source }
            )],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
