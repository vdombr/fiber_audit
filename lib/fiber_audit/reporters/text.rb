# frozen_string_literal: true

require_relative 'base'
require_relative 'schema'
require_relative '../version'
require_relative '../findings/severity'

module FiberAudit
  module Reporters
    # Text reporter that outputs human-readable audit results.
    class Text < Base
      # ANSI owns all escape sequences. Color is applied only to severity labels.
      module ANSI
        RESET = "\e[0m"
        BOLD = "\e[1m"
        DIM = "\e[2m"

        RED = "\e[31m"
        YELLOW = "\e[33m"
        GREEN = "\e[32m"
        BLUE = "\e[34m"
        CYAN = "\e[36m"
        WHITE = "\e[37m"

        SEVERITY_COLORS = {
          critical: RED,
          high: YELLOW,
          medium: YELLOW,
          low: GREEN,
          info: BLUE
        }.freeze

        module_function

        def colorize(text, color_code)
          "#{color_code}#{text}#{RESET}"
        end

        def severity_label(severity, color:)
          label = severity.to_s.upcase
          return label unless color

          color_code = SEVERITY_COLORS[severity.to_sym] || WHITE
          colorize(label, color_code)
        end
      end

      def initialize(color: false)
        @color = color
      end

      def render(result)
        # Validate and get deterministic hash (also triggers all validation)
        hash = Schema.validate!(result)
        lines = []

        # Header
        lines << header
        lines << ''

        # Summary
        lines << summary_section(hash[:summary])
        lines << ''

        # Suppressed
        lines << suppressed_section(hash[:summary])
        lines << ''

        # Status
        lines << status_section(hash[:status])
        lines << ''

        # Mandatory disclaimer
        lines << disclaimer_section
        lines << ''

        # Findings (use original objects, sorted by schema)
        lines << findings_section(hash[:findings])
        lines << ''

        # Footer hint (always present)
        lines << footer_hint

        lines.join("\n") + "\n"
      end

      private

      def header
        "FiberAudit Report v#{FiberAudit::VERSION} (schema #{Schema::SCHEMA_VERSION})"
      end

      def summary_section(summary)
        lines = ['Summary:']
        %i[critical high medium low info].each do |sev|
          count = summary[sev]
          label = ANSI.severity_label(sev, color: @color)
          lines << "  #{label}: #{count}"
        end
        lines << "  Suppressed: #{summary[:suppressed]}"
        lines << "  Total active: #{summary[:total_active]}"
        lines.join("\n")
      end

      def suppressed_section(summary)
        "Suppressed findings: #{summary[:suppressed]}"
      end

      def status_section(status)
        "Status: #{status}"
      end

      def disclaimer_section
        Schema::DISCLAIMER
      end

      def findings_section(findings)
        if findings.empty?
          return 'No findings.'
        end

        lines = ['Findings:']
        findings.each_with_index do |finding, idx|
          lines << format_finding(finding, idx + 1)
        end
        lines.join("\n")
      end

      def format_finding(finding, number)
        lines = []
        severity = finding.severity
        label = ANSI.severity_label(severity, color: @color)

        lines << "  #{number}. [#{label}] #{finding.rule_id}"

        # Location - stable "unknown" when absent
        if finding.location
          loc_str = finding.location.path.to_s
          loc_str += ":#{finding.location.line}" if finding.location.line
          loc_str += ":#{finding.location.column}" if finding.location.column
          lines << "     Location: #{loc_str}"
        else
          lines << '     Location: <unknown>'
        end

        # Omit absent symbol
        lines << "     Symbol: #{finding.symbol}" if finding.symbol

        # Omit absent operation
        lines << "     Operation: #{finding.operation}" if finding.operation

        # Omit absent execution_context
        lines << "     Context: #{finding.execution_context}" if finding.execution_context

        lines << "     Confidence: #{finding.confidence}"
        lines << "     Message: #{finding.message}"

        # Evidence
        if finding.evidence && !finding.evidence.empty?
          lines << '     Evidence:'
          finding.evidence.each do |ev|
            lines << "       - #{ev.source}: #{ev.message}"
          end
        end

        lines.join("\n")
      end

      def footer_hint
        label = @color ? ANSI.colorize('Hint:', ANSI::CYAN) : 'Hint:'
        "#{label} Use --format json for machine-readable output."
      end
    end
  end
end
