# frozen_string_literal: true

require 'yaml'
require 'prism'

module FiberAudit
  module Suppressions
    InlineSuppression = Data.define(:rule_id, :reason, :path, :start_line, :end_line)
    YamlSuppression = Data.define(:rule, :symbol, :operation, :reason)

    class Parser
      # Parses inline suppressions from a file's content using Prism for comment detection.
      # Returns Array[InlineSuppression]
      def self.parse_inline(path, content)
        result = Prism.parse(content)
        return [] if result.errors.any?

        result.comments.filter_map do |comment|
          parse_suppression_comment(comment, content, path)
        end
      end

      # Parse a single comment for suppression directives
      def self.parse_suppression_comment(comment, content, path)
        text = comment.location.slice
        return nil unless text.match?(/fiber-audit:disable\s+FA\d+/)

        rule_id = extract_rule_id(text)
        return nil unless rule_id

        reason = extract_reason(text, path, comment.location.start_line)
        start_line = comment.location.start_line
        end_line = calculate_end_line(content, start_line, rule_id)

        InlineSuppression.new(
          rule_id: rule_id,
          reason: reason,
          path: path,
          start_line: start_line,
          end_line: end_line
        )
      end

      # Extract rule ID from comment text
      def self.extract_rule_id(text)
        match = text.match(/fiber-audit:disable\s+(FA\d+)/)
        match ? match[1] : nil
      end

      # Extract and validate reason from comment text
      def self.extract_reason(text, path, line_number)
        match = text.match(/--\s+(.+)$/)
        if match.nil? || match[1].strip.empty?
          raise FiberAudit::ConfigurationError,
                "Inline suppression at #{path}:#{line_number} missing reason (use -- <reason>)"
        end
        match[1].strip
      end

      # Calculate end line based on whether it's block form or single-line
      def self.calculate_end_line(content, start_line, rule_id)
        line = content.lines[start_line - 1]
        is_block = line.strip.start_with?('#')

        is_block ? find_enable(content.lines, start_line, rule_id) : start_line
      end

      # Parses YAML suppressions file.
      # Returns Array[YamlSuppression]
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

      # Helper method to find matching enable directive
      def self.find_enable(lines, start_idx, rule_id)
        (start_idx...lines.size).each do |i|
          line = lines[i]
          return i + 1 if line.match?(/fiber-audit:enable\s+#{Regexp.escape(rule_id)}/)
        end
        lines.size
      end
    end
  end
end
