# frozen_string_literal: true

require_relative '../errors'

module FiberAudit
  module Runtime
    module Validation
      IDENTIFIER = /\A[a-z][a-z0-9_]*\z/
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      CONTROL = /[[:cntrl:]]/
      OPERATION = /\A(?:::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*(?:[.#](?:[a-zA-Z_][a-zA-Z0-9_]*[!?=]?|\[\]=?))\z/
      SPECIAL_OPERATIONS = %w[Thread.current.[] Thread.current.[]=].freeze

      module_function

      def identifier(value, field, max_bytes: 64)
        normalized = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
        unless normalized&.match?(IDENTIFIER) && normalized.bytesize <= max_bytes
          raise RuntimeContractError, "#{field} must be a snake-case identifier"
        end

        normalized.to_sym
      end

      def string(value, field, max_bytes:, allow_nil: false)
        return if value.nil? && allow_nil
        unless value.is_a?(String) && value.valid_encoding? && !value.empty? &&
               value.bytesize <= max_bytes && !value.match?(CONTROL)
          raise RuntimeContractError, "#{field} must be a non-empty UTF-8 String without control characters"
        end

        value.dup.freeze
      end

      def operation(value, allow_nil: false)
        return if value.nil? && allow_nil

        normalized = string(value, 'operation', max_bytes: 256)
        unless normalized == '[redacted]' || SPECIAL_OPERATIONS.include?(normalized) || normalized.match?(OPERATION)
          raise RuntimeContractError, 'operation must be canonical or redacted'
        end

        normalized
      end

      def integer(value, field, minimum: 0, allow_nil: false)
        return if value.nil? && allow_nil
        unless value.is_a?(Integer) && value >= minimum
          raise RuntimeContractError, "#{field} must be an Integer >= #{minimum}"
        end

        value
      end

      def finite_number(value, field)
        raise RuntimeContractError, "#{field} must be a finite number" unless value.is_a?(Numeric) && value.finite?

        value
      end

      def utc_time(value, field)
        raise RuntimeContractError, "#{field} must be a Time" unless value.is_a?(Time)

        value.getutc.freeze
      end
    end
  end
end
