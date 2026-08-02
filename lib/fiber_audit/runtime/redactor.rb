# frozen_string_literal: true

require 'pathname'
require_relative 'location'
require_relative 'policy'

module FiberAudit
  module Runtime
    class Redactor
      REDACTED = '[redacted]'
      EXTERNAL = '[external]'
      WINDOWS_ABSOLUTE = %r{\A[A-Za-z]:/}

      attr_reader :root, :policy

      def initialize(root:, policy: Policy.new)
        raise RuntimeContractError, 'policy must be a FiberAudit::Runtime::Policy' unless policy.is_a?(Policy)

        safe_root = Validation.string(root, 'root', max_bytes: 4_096)
        @root = canonical_root(safe_root).freeze
        @policy = policy
        freeze
      rescue ArgumentError
        raise RuntimeContractError, 'root is invalid'
      end

      def location(path:, line: nil, column: nil)
        Location.new(path: redact_path(path), line: line, column: column)
      rescue RuntimeContractError
        Location.new(path: REDACTED, line: nil, column: nil)
      end

      def operation(value)
        return if value.nil?

        text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
        return REDACTED unless text&.valid_encoding? && text.bytesize <= 256
        return REDACTED if text.match?(Validation::CONTROL)
        return REDACTED unless text.match?(Validation::OPERATION)

        text.dup.freeze
      end

      private

      def canonical_root(value)
        normalized = value.tr('\\', '/')
        return Pathname.new(normalized).cleanpath.to_s if windows_absolute?(normalized)

        Pathname.new(normalized).expand_path.cleanpath.to_s.tr('\\', '/')
      end

      def redact_path(value)
        return REDACTED unless value.is_a?(String) && value.valid_encoding? && !value.empty?
        return REDACTED if value.bytesize > Location::MAX_PATH_BYTES || value.match?(Validation::CONTROL)

        normalized = value.tr('\\', '/')
        return absolute_path(normalized) if windows_absolute?(normalized)

        path = Pathname.new(normalized)
        return relative_path(path) unless path.absolute?

        absolute_path(path.expand_path.cleanpath.to_s.tr('\\', '/'))
      rescue ArgumentError
        REDACTED
      end

      def absolute_path(path)
        clean = Pathname.new(path).cleanpath.to_s.tr('\\', '/')
        return EXTERNAL unless inside_root?(clean)

        clean[(root.length + 1)..]
      end

      def relative_path(path)
        clean = path.cleanpath
        value = clean.to_s
        return EXTERNAL if value == '..' || value.start_with?('../')
        return REDACTED if value == '.'

        value
      end

      def inside_root?(path)
        candidate, boundary = comparable_paths(path)
        candidate.start_with?("#{boundary}/")
      end

      def comparable_paths(path)
        if windows_absolute?(path) && windows_absolute?(root)
          [path.downcase, root.downcase]
        else
          [path, root]
        end
      end

      def windows_absolute?(path)
        path.match?(WINDOWS_ABSOLUTE)
      end
    end
  end
end
