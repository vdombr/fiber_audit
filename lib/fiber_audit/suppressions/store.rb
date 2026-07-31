# frozen_string_literal: true

module FiberAudit
  module Suppressions
    class Store
      attr_reader :inline_suppressions, :yaml_suppressions

      def initialize(inline_suppressions: [], yaml_suppressions: [])
        @inline_suppressions = inline_suppressions
        @yaml_suppressions = yaml_suppressions
      end

      # Returns [active_findings, suppressed_findings]
      def apply(findings)
        suppressed = []
        active = []

        findings.each do |finding|
          if suppressed?(finding)
            suppressed << finding
          else
            active << finding
          end
        end

        [active, suppressed]
      end

      private

      def suppressed?(finding)
        return true if yaml_suppressed?(finding)
        return true if inline_suppressed?(finding)

        false
      end

      def yaml_suppressed?(finding)
        @yaml_suppressions.any? do |sup|
          next false unless sup.rule == finding.rule_id
          next false if sup.symbol && sup.symbol != finding.symbol
          next false if sup.operation && sup.operation != finding.operation

          true
        end
      end

      def inline_suppressed?(finding)
        return false unless finding.location

        path = finding.location.path
        line = finding.location.line

        @inline_suppressions.any? do |sup|
          sup.path == path && line >= sup.start_line && line <= sup.end_line &&
            sup.rule_id == finding.rule_id
        end
      end
    end
  end
end
