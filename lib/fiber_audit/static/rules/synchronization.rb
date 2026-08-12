# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1003: Thread synchronization primitives that may interfere with
      # fiber scheduler cooperation. Advisory rule with :low default.
      #
      # Detects Mutex, ConditionVariable, Monitor, and MonitorMixin
      # synchronization operations. try_lock is treated as :info since
      # it's non-blocking but indicates thread-oriented synchronization.
      class Synchronization < Base
        id 'FA1003'
        severity :low
        default_confidence :high
        description 'Thread synchronization may interfere with fiber scheduler cooperation'

        RULE_TITLE = 'Thread synchronization'
        RULE_CATEGORY = :synchronization
        TARGETS = OperationVocabulary::FA1003_TARGETS
        TRY_LOCK_MSG = 'Mutex#try_lock is non-blocking and identifies a thread-oriented coordination point.'
        NORMAL_MSG = 'Synchronization contention requires scheduler block/unblock cooperation in a non-blocking Fiber.'
        REMEDIATION = 'Verify scheduler coordination and contention behavior under load; investigate correlated stalls.'

        def analyze(call_sites:)
          explicit_monitor_mixins = explicit_monitor_mixin_classes(call_sites)
          call_sites.filter_map { |site| check(site, explicit_monitor_mixins) }
        rescue StandardError
          []
        end

        private

        def check(site, explicit_monitor_mixins)
          if site.receiver_source.nil? && site.receiver_constant.nil? && site.method_name == :synchronize
            klass = extract_class_name(site.enclosing_symbol)
            semantic_match = klass && monitor_mixin_ancestor?(klass)
            return unless semantic_match || explicit_monitor_mixins.include?(klass)
            return if workspace_shadow?('MonitorMixin', site.nesting)

            return build_finding(site, 'MonitorMixin', :synchronize)
          end

          target = site.receiver_constant
          return unless target && TARGETS.fetch(target, []).include?(site.method_name)
          return if workspace_shadow?(target, site.nesting) || site.receiver_source == target

          build_finding(site, target, site.method_name)
        rescue StandardError
          nil
        end

        def workspace_shadow?(target, nesting)
          index = workspace_index
          return false unless index.respond_to?(:resolve_constant)

          !index.resolve_constant(target, nesting: nesting || []).nil?
        rescue StandardError
          false
        end

        def workspace_index
          index = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          index || (workspace if workspace.respond_to?(:resolve_constant))
        rescue StandardError
          nil
        end

        def extract_class_name(symbol)
          return unless symbol

          separator = symbol.include?('#') ? '#' : '.'
          symbol.split(separator, 2).first if symbol.include?(separator)
        end

        def monitor_mixin_ancestor?(class_name)
          adapters = [workspace]
          adapters << workspace.semantic_index if workspace.respond_to?(:semantic_index)
          adapters.compact.uniq.any? do |adapter|
            adapter.respond_to?(:ancestors_of) &&
              Array(adapter.ancestors_of(class_name)).include?('MonitorMixin')
          rescue StandardError
            false
          end
        end

        def explicit_monitor_mixin_classes(call_sites)
          call_sites.filter_map do |site|
            next unless site.receiver_source.nil? && site.method_name == :include
            next unless Array(site.arguments).any? { |argument| argument.to_s.delete_prefix('::') == 'MonitorMixin' }

            Array(site.nesting).last
          end.uniq
        end

        def build_finding(site, target, method)
          try_lock = target == 'Mutex' && method == :try_lock
          operation = "#{target}##{method}"
          # try_lock has fixed :info, no config override
          severity = try_lock ? :info : advisory_severity(:low)
          confidence = try_lock ? :high : site.confidence
          message = try_lock ? TRY_LOCK_MSG : NORMAL_MSG
          evidence = Evidence.new(source: operation, message: message,
                                  details: { receiver: site.receiver_source, method: method.to_s, constant: target })

          Finding.new(
            rule_id: self.class.id, title: RULE_TITLE, category: RULE_CATEGORY,
            severity: severity, confidence: confidence, location: site.location,
            symbol: site.enclosing_symbol, operation: operation,
            execution_context: site.execution_context, message: message,
            evidence: [evidence], remediation: REMEDIATION
          )
        rescue StandardError
          nil
        end
      end
    end
  end
end
