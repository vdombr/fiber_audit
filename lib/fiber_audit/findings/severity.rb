# frozen_string_literal: true

module FiberAudit
  module Severity
    LEVELS = %i[critical high medium low info].freeze

    module_function

    def coerce(value)
      return value if LEVELS.include?(value)

      raise ArgumentError, "unknown severity: #{value.inspect}"
    end

    def index(severity)
      LEVELS.index(severity) || LEVELS.size
    end
  end
end
