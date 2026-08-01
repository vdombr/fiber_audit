# frozen_string_literal: true

module FiberAudit
  module Reporters
    # Base class for all reporters. Subclasses must implement #render.
    class Base
      def render(_result)
        raise NotImplementedError, "#{self.class}#render must be implemented"
      end
    end
  end
end
