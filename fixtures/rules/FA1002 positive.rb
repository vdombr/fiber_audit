# frozen_string_literal: true

# Positive test cases for FA1002: Thread#join and Thread#value detection
#
# These patterns should be detected by the rule.

class ThreadJoinPositiveCases
  # Direct constructor chain - Thread.new.join
  def direct_chain_join
    Thread.new { 'work' }.join
  end

  # Direct constructor chain - Thread.new.value
  def direct_chain_value
    Thread.new { 'result' }.value
  end

  # Assigned receiver - t = Thread.new; t.join
  def assigned_receiver_join
    thread = Thread.new { 'work' }
    thread.join
  end

  # Assigned receiver - t = Thread.new; t.value
  def assigned_receiver_value
    thread = Thread.new { 'result' }
    thread.value
  end

  # Thread.current - forces high confidence
  def thread_current_join
    Thread.current.join
  end

  # Thread.current.value
  def thread_current_value
    Thread.current.value
  end

  # Multiple assigned receivers
  def multiple_threads
    worker1 = Thread.new { 'work1' }
    worker2 = Thread.new { 'work2' }
    worker1.join
    worker2.value
  end

  # Thread.current in different contexts
  def request_context_example
    current = Thread.current
    current.join
  end
end
