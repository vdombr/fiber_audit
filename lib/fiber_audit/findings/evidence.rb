# frozen_string_literal: true

module FiberAudit
  Evidence = Data.define(:source, :message, :details) do
    def initialize(source:, message:, details: {})
      super(source: source, message: message, details: details || {})
    end

    def to_h_for_json
      { source: source, message: message, details: details }
    end
  end
end
