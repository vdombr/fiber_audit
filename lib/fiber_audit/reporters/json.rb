# frozen_string_literal: true

require 'json'
require_relative 'base'
require_relative 'schema'

module FiberAudit
  module Reporters
    # JSON reporter that outputs deterministic, schema-validated JSON.
    # Calls Schema.build then Schema.validate! to enforce the contract.
    class JSON < Base
      def initialize(pretty: false)
        super()
        @pretty = pretty
      end

      def render(result)
        # Build normalized primitive report hash from result protocol
        report_hash = Schema.build(result)

        # Validate the hash and return it (also freezes it)
        Schema.validate!(report_hash)

        json_string = if @pretty
                        ::JSON.pretty_generate(report_hash)
                      else
                        ::JSON.generate(report_hash)
                      end

        "#{json_string}\n"
      end
    end
  end
end
