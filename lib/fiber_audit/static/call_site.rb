# frozen_string_literal: true

module FiberAudit
  module Static
    # CallSite represents a single method call extracted from source code.
    # Carries exactly 13 fields as specified in the remediation plan.
    CallSite = Data.define(
      :path, :line, :column,
      :receiver_source, :receiver_constant, :method_name,
      :arguments, :enclosing_symbol, :nesting,
      :execution_context, :resolution, :confidence
    ) do
      # Override initialize to ensure method_name is stored as Symbol
      def initialize(
        path:, line:, column:,
        receiver_source:, receiver_constant:, method_name:,
        arguments:, enclosing_symbol:, nesting:,
        execution_context:, resolution:, confidence:
      )
        # Normalize method_name to Symbol if it's a String
        method_name_sym = method_name.is_a?(String) ? method_name.to_sym : method_name

        super(
          path: path,
          line: line,
          column: column,
          receiver_source: receiver_source,
          receiver_constant: receiver_constant,
          method_name: method_name_sym,
          arguments: arguments,
          enclosing_symbol: enclosing_symbol,
          nesting: nesting,
          execution_context: execution_context,
          resolution: resolution,
          confidence: confidence
        )
      end

      # Returns a Location object for this call site
      def location
        FiberAudit::Location.new(path: path, line: line, column: column)
      end

      # Returns method_name as a Symbol (convenience accessor)
      def method_name_sym
        method_name
      end
    end
  end
end
