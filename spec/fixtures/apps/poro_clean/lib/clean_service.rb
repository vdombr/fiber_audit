# frozen_string_literal: true

class CleanService
  def call(values)
    values.map(&:to_s).join(',')
  end
end
