# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1004: Detect thread-variable state access.
      #
      # Detects only thread_variable_get/set operations, not Thread.current[]
      # index operations. Thread variables are shared across all fibers on the
      # same thread and may leak request-local data.
      class ThreadCurrentState < Base
        id 'FA1004'
        severity :high
        confidence :high
        description 'Thread thread variables in fiber code may be shared across fibers and leak request-local data'

        TITLE = 'Thread thread variables in fiber code'
        CATEGORY = :thread_local
        MESSAGE = 'Thread thread variables are shared across all fibers on the same thread ' \
                  'and may leak request-local data between concurrent requests.'
        REMEDIATION = 'Prefer fiber-local storage (Fiber.current[:key]) or framework-provided ' \
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

          build_finding(site, :high, :high, operation(site))
        end

        def operation(site)
          "Thread.#{site.method_name}"
        end

        def build_finding(site, default_sev, conf, operation)
          context = site.execution_context
          severity = severity_for(default_sev, context)

          Finding.new(
            rule_id: self.class.id,
            title: TITLE,
            category: CATEGORY,
            severity: severity,
            confidence: conf,
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: operation,
            execution_context: context,
            message: MESSAGE,
            evidence: [Evidence.new(
              source: site.receiver_source,
              message: "Thread thread variable access via #{site.method_name}",
              details: { operation: operation, receiver: site.receiver_source }
            )],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
