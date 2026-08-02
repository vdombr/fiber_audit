# frozen_string_literal: true

class SampleRecord < ActiveRecord::Base
  def before_save
    puts 'callback'
  end
end
