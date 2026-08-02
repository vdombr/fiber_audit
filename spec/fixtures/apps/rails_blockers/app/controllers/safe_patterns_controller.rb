# frozen_string_literal: true

class SafePatternsController < ApplicationController
  def index
    Kernel.puts('safe')
    Worker.new.join
    Mutex.new.unlock
    Fiber.current[:request_id]
    IO.read('README.md')
    Socket.open('example.com', 80)
    Net::HTTP.get_print(URI('https://example.com/status'))
  end
end
