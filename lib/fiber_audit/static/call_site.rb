# frozen_string_literal: true

require_relative '../findings/location'
require_relative '../findings/confidence'

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
      # Override initialize to ensure proper contract:
      # - method_name normalized to Symbol or nil
      # - confidence validated via Confidence.coerce
      # - arguments and nesting frozen to prevent caller mutation
      def initialize(
        path:, line:, column:,
        receiver_source:, receiver_constant:, method_name:,
        arguments:, enclosing_symbol:, nesting:,
        execution_context:, resolution:, confidence:
      )
        # Normalize method_name to Symbol if it's a String, preserve nil
        method_name_value = case method_name
                            when String
                              method_name.to_sym
                            when Symbol, nil
                              method_name
                            else
                              raise ArgumentError,
                                    "method_name must be String, Symbol, or nil, got #{method_name.class}"
                            end

        # Validate confidence via Confidence.coerce
        validated_confidence = Confidence.coerce(confidence)

        # Freeze duplicates of mutable collections to prevent caller mutation
        frozen_arguments = arguments.dup.freeze
        frozen_nesting = nesting.dup.freeze

        super(
          path: path,
          line: line,
          column: column,
          receiver_source: receiver_source,
          receiver_constant: receiver_constant,
          method_name: method_name_value,
          arguments: frozen_arguments,
          enclosing_symbol: enclosing_symbol,
          nesting: frozen_nesting,
          execution_context: execution_context,
          resolution: resolution,
          confidence: validated_confidence
        )
      end

      # Returns a Location object for this call site
      def location
        FiberAudit::Location.new(path: path, line: line, column: column)
      end

      # Returns method_name as a Symbol or nil (convenience accessor)
      def method_name_sym
        method_name
      end
    end
  end
end
