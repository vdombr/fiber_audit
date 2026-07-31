# frozen_string_literal: true

module FiberAudit
  Location = Data.define(:path, :line, :column) do
    def to_h_for_json
      { path: path, line: line, column: column }
    end
  end
end
