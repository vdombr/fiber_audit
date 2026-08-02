# frozen_string_literal: true

class ConstructorChain
  def assignment_based
    # Assignment-based propagation (existing behavior)
    thread = Thread.new { 'work' }
    thread.join

    mutex = Mutex.new
    mutex.synchronize { 'critical' }
  end

  def direct_chains
    # Direct constructor chains: Thread.new.join
    Thread.new { 'work' }.join

    # Direct constructor chains: Mutex.new.synchronize
    Mutex.new.synchronize { 'critical' }
  end

  def current_thread_assignment
    current_thread = Thread.current
    current_thread.thread_variable_get(:request_id)
  end

  def attached_block_body
    1.times do
      IO.select([], [], [], 0)
    end
  end
end
