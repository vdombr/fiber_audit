# frozen_string_literal: true

class SampleChannel < ActionCable::Channel::Base
  def subscribed
    puts 'websocket'
  end
end
