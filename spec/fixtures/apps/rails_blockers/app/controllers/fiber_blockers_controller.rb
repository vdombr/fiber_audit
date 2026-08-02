# frozen_string_literal: true

class FiberBlockersController < ApplicationController
  def index
    system('generate-report')
    Thread.new { :done }.join
    Mutex.new.lock
    Thread.current[:request_id]
    IO.select([], [], [], 0)
    TCPSocket.new('example.com', 80)
    Net::HTTP.get(URI('https://example.com/status'))
  end
end
