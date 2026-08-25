# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../findings/finding'
require_relative '../../operation_semantics'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      class BlockingFiberContext < Base
        id 'FA1008'
        severity :low
        confidence :high
        description 'Explicit blocking Fiber contexts bypass scheduler cooperation'

        TITLE = 'Blocking Fiber execution context'
        CATEGORY = :fiber_context
        MESSAGE = 'This lexical region explicitly uses blocking Fiber execution, ' \
                  'so scheduler hooks do not apply within it.'
        WAIT_MESSAGE = 'This blocking Fiber region contains operations that may wait without scheduler cooperation.'
        REMEDIATION = 'Keep scheduler-aware work outside explicit blocking Fiber regions, ' \
                      'or document and suppress intentional scheduler-internal boundaries.'
        OPERATIONS = OperationVocabulary::FA1008_OPERATIONS.values.freeze

        def analyze(call_sites:)
          sites = Array(call_sites)
          sites.filter_map do |site|
            next unless blocking_region_site?(site)
            next if shadowed?('Fiber', site.nesting)

            nested_waits = nested_waits_for(site, sites)
            build_finding(site, nested_waits)
          end
        end

        private

        def blocking_region_site?(site)
          context = site.fiber_context
          return false unless context&.starts_at?(site)
          return false unless site.receiver_constant == 'Fiber'
          return false unless ['Fiber', '::Fiber'].include?(site.receiver_source)

          expected_method = context.kind == :fiber_new ? :new : :blocking
          site.method_name == expected_method
        rescue StandardError
          false
        end

        def nested_waits_for(region_site, sites)
          sites.filter_map do |site|
            next if site.equal?(region_site) || site.path != region_site.path
            next unless site.fiber_context == region_site.fiber_context

            operation = canonical_wait_operation(site)
            next unless operation

            { operation: operation, line: site.line, column: site.column, confidence: site.confidence }.freeze
          end.uniq.freeze
        end

        def canonical_wait_operation(site)
          receiver = site.receiver_constant
          method = site.method_name
          return unless method
          return if receiver && shadowed?(receiver, site.nesting)

          candidates = if receiver
                         receiver_candidates(site, receiver, method)
                       elsif site.receiver_source.nil?
                         ["Kernel.#{method}"]
                       else
                         []
                       end
          candidates.find { |operation| OperationSemantics.resolve(operation).wait_possible == true }
        rescue RuntimeContractError
          nil
        end

        def receiver_candidates(site, receiver, method)
          return [] if receiver == 'Thread' && ['Thread', '::Thread'].include?(site.receiver_source)

          ["#{receiver}.#{method}", "#{receiver}##{method}"].uniq
        end

        def shadowed?(constant_name, nesting)
          index = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          index ||= workspace if workspace.respond_to?(:resolve_constant)
          return false unless index.respond_to?(:resolve_constant)

          !index.resolve_constant(constant_name, nesting: nesting || []).nil?
        rescue StandardError
          false
        end

        def build_finding(site, nested_waits)
          context = site.fiber_context
          has_wait = !nested_waits.empty?
          evidence = [Evidence.new(
            source: 'static_analysis',
            message: "Explicit blocking Fiber context: #{context.operation}",
            details: { operation: context.operation, context_kind: context.kind, nested_wait_count: nested_waits.size }
          )]
          evidence.concat(nested_waits.map do |wait|
            Evidence.new(source: 'static_analysis',
                         message: "Lexically nested wait-capable operation: #{wait.fetch(:operation)}", details: wait)
          end)

          Finding.new(
            rule_id: self.class.id,
            title: TITLE,
            category: CATEGORY,
            severity: advisory_severity(has_wait ? :medium : :low),
            confidence: :high,
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: context.operation,
            execution_context: site.execution_context || :unknown,
            message: has_wait ? WAIT_MESSAGE : MESSAGE,
            evidence: evidence,
            remediation: REMEDIATION
          )
        end
      end
    end
  end
end
