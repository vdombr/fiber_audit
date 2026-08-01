# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'

module FiberAudit
  module Static
    module Rules
      # Detect thread-variable and Thread.current index state.
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
        INDEX_METHODS = %i[[] []=].freeze

        def analyze(call_sites:)
          findings = []
          call_sites.each do |site|
            next if skip?(site)

            finding = match_thread_variable(site) || match_index_op(site)
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

        def match_index_op(site)
          return unless INDEX_METHODS.include?(site.method_name)
          return unless site.receiver_source == 'Thread.current'

          build_finding(site, :medium, :high, operation(site))
        end

        def operation(site)
          if INDEX_METHODS.include?(site.method_name)
            "Thread.current.#{site.method_name}"
          else
            "Thread.#{site.method_name}"
          end
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
            evidence: [Evidence.new(source: site.receiver_source, message: "Thread-local access via #{site.method_name}")],
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
