# frozen_string_literal: true

module FiberAudit
  module Confidence
    LEVELS = %i[confirmed high medium low unknown].freeze

    module_function

    def coerce(value)
      return value if LEVELS.include?(value)

      raise ArgumentError, "unknown confidence: #{value.inspect}"
    end

    def index(confidence)
      LEVELS.index(confidence) || LEVELS.size
    end
  end
end
