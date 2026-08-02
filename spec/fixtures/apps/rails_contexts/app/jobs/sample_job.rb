# frozen_string_literal: true

class SampleJob < ActiveJob::Base
  def perform
    puts 'job'
  end
end
