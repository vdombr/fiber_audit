# frozen_string_literal: true

require 'digest'
require 'pathname'

module FiberAudit
  module Correlation
    module Fingerprint
      module_function

      def call(rule_id:, path:, enclosing_symbol:, operation:)
        Digest::SHA256.hexdigest(
          [rule_id, normalize_path(path), enclosing_symbol, operation].join(':')
        )
      end

      def normalize_path(path)
        return '' if path.nil?

        Pathname.new(path).cleanpath.to_s
      rescue ArgumentError
        path.to_s
      end
    end
  end
end
