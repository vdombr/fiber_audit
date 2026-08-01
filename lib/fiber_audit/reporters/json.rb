# frozen_string_literal: true

require 'json'
require_relative 'base'
require_relative 'schema'

module FiberAudit
  module Reporters
    # JSON reporter that outputs deterministic, schema-validated JSON.
    class JSON < Base
      def initialize(pretty: false)
        @pretty = pretty
      end

      def render(result)
        hash = Schema.validate!(result)
        json_hash = normalize_for_json(hash)

        json_string = if @pretty
                        ::JSON.pretty_generate(json_hash)
                      else
                        ::JSON.generate(json_hash)
                      end

        "#{json_string}\n"
      end

      private

      def normalize_for_json(obj)
        case obj
        when Hash
          obj.transform_keys(&:to_s).transform_values { |v| normalize_for_json(v) }
        when Array
          obj.map { |item| normalize_for_json(item) }
        when Symbol
          obj.to_s
        else
          if obj.respond_to?(:to_h_for_json)
            normalize_for_json(obj.to_h_for_json)
          else
            obj
          end
        end
      end
    end
  end
end
