# frozen_string_literal: true

require_relative 'base'

module FiberAudit
  module Static
    module Rules
      # FA1003 — Detects thread synchronization primitives that may block fibers.
      class Synchronization < Base
        id 'FA1003'
        severity :medium
        default_confidence :high
        description 'Thread synchronization primitives that may block the fiber scheduler thread'

        RULE_TITLE    = 'Thread synchronization'.freeze
        RULE_CATEGORY = :synchronization

        TARGETS = {
          'Mutex'             => %i[lock synchronize try_lock],
          'ConditionVariable' => %i[wait],
          'Monitor'           => %i[synchronize],
          'MonitorMixin'      => %i[synchronize]
        }.freeze

        TRY_LOCK_SEVERITY   = :info
        TRY_LOCK_CONFIDENCE = :high
        TRY_LOCK_MSG = 'Mutex.try_lock is non-blocking but may indicate thread-oriented synchronization in fiber-scheduled code.'
        NORMAL_MSG = 'Synchronization operation may block the thread running the fiber scheduler.'
        REMEDIATION = 'Use scheduler-aware synchronization primitives, or verify contention and scheduler behaviour under load.'

        def analyze(call_sites:)
          call_sites.filter_map { |site| check(site) }
        rescue StandardError
          []
        end

        private

        def check(site)
          # Implicit synchronize via MonitorMixin inclusion
          if site.receiver_source.nil? && site.receiver_constant.nil? &&
             site.method_name == :synchronize
            klass = extract_class_name(site.enclosing_symbol)
            return unless klass && monitor_mixin_ancestor?(klass)
            return if workspace_shadow?('MonitorMixin', site.nesting)

            return build_finding(site, 'MonitorMixin', :synchronize)
          end

          target = site.receiver_constant
          return unless target && TARGETS.key?(target)

          method = site.method_name
          return unless TARGETS[target].include?(method)
          return if workspace_shadow?(target, site.nesting)
          return if site.receiver_source == target

          build_finding(site, target, method)
        rescue StandardError
          nil
        end

        def workspace_shadow?(target, nesting)
          idx = workspace_index
          return false unless idx&.respond_to?(:resolve_constant)

          !idx.resolve_constant(target, nesting: nesting || []).nil?
        rescue StandardError
          false
        end

        def workspace_index
          ws = workspace
          return ws.semantic_index if ws.respond_to?(:semantic_index)
          return ws if ws.respond_to?(:resolve_constant)
        rescue StandardError
          nil
        end

        def extract_class_name(symbol)
          return nil unless symbol

          symbol.include?('#') ? symbol.split('#', 2).first :
            (symbol.include?('.') ? symbol.split('.', 2).first : nil)
        end

        def monitor_mixin_ancestor?(class_name)
          ws = workspace
          if ws.respond_to?(:ancestors_of)
            ws.ancestors_of(class_name).include?('MonitorMixin')
          elsif ws.respond_to?(:semantic_index) && ws.semantic_index.respond_to?(:ancestors_of)
            ws.semantic_index.ancestors_of(class_name).include?('MonitorMixin')
          else
            false
          end
        rescue StandardError
          false
        end

        def build_finding(site, target, method)
          try_lock = target == 'Mutex' && method == :try_lock
          operation = "#{target}##{method}"
          sev = try_lock ? TRY_LOCK_SEVERITY : severity_for(:medium, site.execution_context)
          conf = try_lock ? TRY_LOCK_CONFIDENCE : site.confidence
          msg = try_lock ? TRY_LOCK_MSG : NORMAL_MSG

          evidence = [Evidence.new(source: operation, message: msg,
                                   details: { receiver: site.receiver_source, method: method.to_s, constant: target })]

          Finding.new(
            rule_id: self.class.id, title: RULE_TITLE, category: RULE_CATEGORY,
            severity: sev, confidence: conf, location: site.location,
            symbol: site.enclosing_symbol, operation: operation,
            execution_context: site.execution_context, message: msg,
            evidence: evidence, remediation: REMEDIATION
          )
        rescue StandardError
          nil
        end
      end
    end
  end
end
