# frozen_string_literal: true

class ConstructorChain
  def create_objects
    thread = Thread.new { 'work' }
    thread.join

    mutex = Mutex.new
    mutex.synchronize { 'critical' }
  end
end
