# frozen_string_literal: true

require_relative 'base'
require_relative 'schema'
require_relative '../version'
require_relative '../findings/severity'

module FiberAudit
  module Reporters
    # Text reporter that outputs human-readable audit results.
    # Calls Schema.build then Schema.validate! to enforce the contract.
    #
    # Exact contract:
    # - Header: `FiberAudit 0.1.0 — static analysis`
    # - Summary counts, suppressed, status
    # - Disclaimer under status
    # - Findings: RULE  SEVERITY  path:line
    # - Optional: symbol — operation [context]
    # - message
    # - (unknown location) fallback
    # - Footer: Run `fiber-audit explain <RULE_ID>` for rule details.
    # - ANSI escape constants only in Text::ANSI
    # - Color ONLY severity labels, not footer/header
    class Text < Base
      # ANSI owns all escape sequences. Color is applied only to severity labels.
      module ANSI
        RESET = "\e[0m"
        BOLD = "\e[1m"
        DIM = "\e[2m"

        RED = "\e[31m"
        YELLOW = "\e[33m"
        MAGENTA = "\e[35m"
        CYAN = "\e[36m"
        WHITE = "\e[37m"

        SEVERITY_COLORS = {
          critical: RED,
          high: YELLOW,
          medium: MAGENTA,
          low: CYAN,
          info: CYAN
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
        super()
        @color = color
      end

      def render(result)
        # Build normalized primitive report hash from result protocol
        report_hash = Schema.build(result)

        # Validate the hash (also freezes it)
        Schema.validate!(report_hash)

        lines = []

        # Header: exact contract
        lines << header
        lines << ''

        # Summary counts and suppressed/status
        lines << summary_section(report_hash[:summary])
        lines << ''

        # Status
        lines << status_section(report_hash[:status])

        # Mandatory disclaimer under status
        lines << disclaimer_section
        lines << ''

        # Findings
        lines << findings_section(report_hash[:findings])
        lines << ''

        # Footer hint is always present, including no-findings reports.
        lines << footer_hint

        "#{lines.join("\n").chomp}\n"
      end

      private

      def header
        "FiberAudit #{FiberAudit::VERSION} — static analysis"
      end

      def summary_section(summary)
        counts = %i[critical high medium low info].map do |severity|
          "#{severity}: #{summary[severity]}"
        end

        [
          'Summary',
          "  #{counts.join('   ')}",
          "  suppressed: #{summary[:suppressed]}",
          "  total: #{summary[:total]}"
        ].join("\n")
      end

      def status_section(status)
        "  status: #{status}"
      end

      def disclaimer_section
        Schema::DISCLAIMER
      end

      def findings_section(findings)
        return 'No findings.' if findings.empty?

        lines = ['Findings']
        findings.each do |finding|
          lines << format_finding(finding)
        end
        lines.join("\n")
      end

      def format_finding(finding)
        lines = []
        severity = finding[:severity].to_sym
        label = ANSI.severity_label(severity, color: @color)

        # RULE  SEVERITY  path:line
        location_str = format_location(finding[:location])
        lines << "  #{finding[:rule_id]}  #{label}  #{location_str}"

        # Optional: symbol — operation [context]
        optional_parts = []
        optional_parts << finding[:symbol] if finding[:symbol]
        if finding[:operation]
          if finding[:symbol]
            optional_parts[-1] = "#{finding[:symbol]} — #{finding[:operation]}"
          else
            optional_parts << finding[:operation]
          end
        end
        optional_parts << "[#{finding[:execution_context]}]" if finding[:execution_context]

        lines << "     #{optional_parts.join(' ')}" if optional_parts.any?

        # message
        lines << "     #{finding[:message]}"

        lines.join("\n")
      end

      def format_location(location)
        return '(unknown location)' if location.nil?

        path = location[:path].to_s
        line = location[:line]

        line ? "#{path}:#{line}" : path
      end

      def footer_hint
        'Run `fiber-audit explain <RULE_ID>` for rule details.'
      end
    end
  end
end
