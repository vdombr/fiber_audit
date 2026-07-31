# frozen_string_literal: true

require 'yaml'
require 'prism'
require_relative '../errors'

module FiberAudit
  module Suppressions
    InlineSuppression = Data.define(:rule_id, :reason, :path, :start_line, :end_line)
    YamlSuppression = Data.define(:rule, :symbol, :operation, :reason)

    class Parser
      # Parses inline suppressions from a file's content using Prism for comment detection.
      # Directives are recognized ONLY from actual Prism comments - never from raw text scans.
      # This ensures directive text in strings, heredocs, and regex literals cannot start or end suppressions.
      def self.parse_inline(path, content)
        result = Prism.parse(content)
        return [] if result.errors.any?

        lines = content.lines
        disables = []
        enables = []

        # Only examine actual comments from Prism
        result.comments.each do |comment|
          text = comment.location.slice
          line_num = comment.location.start_line

          if (match = text.match(/fiber-audit:disable\s+(FA\d+)/))
            rule_id = match[1]
            reason = extract_reason(text, path, line_num)
            is_block = block_comment?(comment, lines)
            disables << {
              rule_id: rule_id,
              reason: reason,
              line: line_num,
              block: is_block
            }
          elsif (match = text.match(/fiber-audit:enable\s+(FA\d+)/))
            enables << {
              rule_id: match[1],
              line: line_num
            }
          end
        end

        build_suppressions(disables, enables, lines, path)
      end

      # Parse YAML suppressions file
      def self.parse_yaml(path)
        return [] unless path && File.exist?(path)

        yaml = YAML.safe_load_file(path) || {}
        raw_suppressions = yaml['suppressions'] || []

        raw_suppressions.map do |entry|
          rule = entry['rule']
          reason = entry['reason']

          if reason.nil? || reason.strip.empty?
            raise FiberAudit::ConfigurationError, "YAML suppression for rule #{rule} at #{path} missing 'reason'"
          end

          YamlSuppression.new(
            rule: rule,
            symbol: entry['symbol'],
            operation: entry['operation'],
            reason: reason.strip
          )
        end
      end

      private

      # Extract and validate reason from comment text
      def self.extract_reason(text, path, line_number)
        match = text.match(/--\s+(.+)$/)
        if match.nil? || match[1].strip.empty?
          raise FiberAudit::ConfigurationError,
                "Inline suppression at #{path}:#{line_number} missing reason (use -- <reason>)"
        end
        match[1].strip
      end

      # Determine if comment is a block comment (only whitespace before #)
      # vs a trailing comment (has code before #)
      def self.block_comment?(comment, lines)
        line = lines[comment.location.start_line - 1]
        prefix = line[0, comment.location.start_column]
        prefix.nil? || prefix.strip.empty?
      end

      # Build InlineSuppression objects, matching enables to disables
      def self.build_suppressions(disables, enables, lines, path)
        used_enable_lines = []

        disables.map do |d|
          end_line = if d[:block]
                       # Find matching enable for this rule_id
                       enable = enables.find do |e|
                         e[:rule_id] == d[:rule_id] &&
                           e[:line] > d[:line] &&
                           !used_enable_lines.include?(e[:line])
                       end
                       if enable
                         used_enable_lines << enable[:line]
                         enable[:line]
                       else
                         # Unmatched block extends to EOF
                         lines.size
                       end
                     else
                       # Trailing comment: suppress only this line
                       d[:line]
                     end

          InlineSuppression.new(
            rule_id: d[:rule_id],
            reason: d[:reason],
            path: path,
            start_line: d[:line],
            end_line: end_line
          )
        end
      end
    end
  end
end
