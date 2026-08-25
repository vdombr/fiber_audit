# frozen_string_literal: true

require_relative '../operation_vocabulary'

module FiberAudit
  module Static
    FiberContext = Data.define(:kind, :line, :column) do
      def initialize(kind:, line:, column:)
        normalized_kind = kind.to_sym if kind.respond_to?(:to_sym)
        unless OperationVocabulary::FA1008_OPERATIONS.key?(normalized_kind)
          raise ArgumentError, "unknown Fiber context kind: #{kind.inspect}"
        end
        raise ArgumentError, 'line must be a positive Integer' unless line.is_a?(Integer) && line.positive?
        raise ArgumentError, 'column must be a non-negative Integer' unless column.is_a?(Integer) && column >= 0

        super(kind: normalized_kind, line: line, column: column)
      end

      def operation = OperationVocabulary::FA1008_OPERATIONS.fetch(kind)
      def starts_at?(call_site) = call_site.line == line && call_site.column == column
    end
  end
end
