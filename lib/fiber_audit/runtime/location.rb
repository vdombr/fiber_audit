# frozen_string_literal: true

require 'pathname'
require_relative 'validation'

module FiberAudit
  module Runtime
    Location = Data.define(:path, :line, :column) do
      def initialize(path:, line: nil, column: nil)
        super(
          path: normalize_path(path),
          line: Validation.integer(line, 'line', minimum: 1, allow_nil: true),
          column: Validation.integer(column, 'column', allow_nil: true)
        )
      end

      private

      def normalize_path(value)
        path = Validation.string(value, 'path', max_bytes: Location::MAX_PATH_BYTES)
        return path if Location::SENTINELS.include?(path)

        normalized = path.tr('\\', '/')
        raise RuntimeContractError, 'path must be project-relative' if absolute_path?(normalized)

        clean = Pathname.new(normalized).cleanpath.to_s
        if clean == '.' || clean == '..' || clean.start_with?('../')
          raise RuntimeContractError, 'path must not escape the project root'
        end

        clean.freeze
      rescue ArgumentError
        raise RuntimeContractError, 'path is invalid'
      end

      def absolute_path?(path)
        path.start_with?('/', '//') || path.match?(%r{\A[A-Za-z]:/})
      end
    end

    Location.const_set(:SENTINELS, %w[[external] [redacted]].freeze)
    Location.const_set(:MAX_PATH_BYTES, 1_024)
  end
end
