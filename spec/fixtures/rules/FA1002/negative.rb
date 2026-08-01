# frozen_string_literal: true

# Negative test cases for FA1002: Thread#join and Thread#value detection
#
# These patterns should NOT be detected by the rule.

class ThreadJoinNegativeCases
  # Direct Thread.join - should be skipped (bare Thread literal)
  def direct_thread_join
    Thread.join
  end

  # Direct Thread.value - should be skipped (bare Thread literal)
  def direct_thread_value
    Thread.value
  end

  # Arbitrary worker.join - should be skipped (not a Thread)
  def arbitrary_worker_join
    worker = Worker.new
    worker.join
  end

  # Wrong method - should be skipped (not :join or :value)
  def wrong_method_kill
    thread = Thread.new { 'work' }
    thread.kill
  end

  # Wrong method - should be skipped
  def wrong_method_run
    thread = Thread.new { 'work' }
    thread.run
  end

  # Wrong method - should be skipped
  def wrong_method_raise
    thread = Thread.new { 'work' }
    thread.raise
  end

  # Nil receiver_constant - should be skipped
  def unknown_receiver_join
    some_object.join
  end

  # Different class entirely
  def different_class_join
    mutex = Mutex.new
    mutex.lock
  end

  # Custom shadowed Thread (if workspace resolves Thread to something else)
  # This would be detected as shadowed if workspace.resolve_constant('Thread') != 'Thread'
  def custom_thread_class
    # In a real scenario, if Thread is redefined or shadowed
    # The workspace adapter would detect this
    custom_thread = CustomThread.new
    custom_thread.join
  end
end

# Helper classes for negative cases
class Worker
  def join
    # Not a Thread
  end
end

class CustomThread
  def join
    # Not the real Thread class
  end
end
