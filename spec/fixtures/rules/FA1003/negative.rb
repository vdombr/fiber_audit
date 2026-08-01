# frozen_string_literal: true

# Negative fixtures for FA1003 - Thread synchronization rule
# These patterns should NOT trigger findings

class SafeWorker
  # Direct constant receiver (class method call, not instance) - should NOT match
  def class_method_call
    Mutex.lock  # NOT FA1003: Direct constant receiver
    Monitor.synchronize { }  # NOT FA1003: Direct constant receiver
  end

  # Unrelated methods on target constants - should NOT match
  def unrelated_methods
    mutex = Mutex.new
    mutex.new  # NOT FA1003: :new is not a target method
    mutex.unlock  # NOT FA1003: :unlock is not a target method
  end

  # Non-target constants - should NOT match
  def non_target_constants
    thread = Thread.new { sleep 1 }
    thread.join  # NOT FA1003: Thread is not a target
    array = []
    array.lock  # NOT FA1003: Array is not a target
  end

  # Implicit synchronize without MonitorMixin - should NOT match
  class PlainService
    def process
      synchronize { }  # NOT FA1003: No MonitorMixin ancestry
    end
  end

  # Wrong implicit method - should NOT match
  class MonitoredButWrongMethod
    include MonitorMixin

    def process
      lock  # NOT FA1003: :lock is not :synchronize
    end
  end

  # Workspace shadow - should NOT match
  # (This would require semantic index to report Mutex as workspace-defined)
  # class Mutex
  #   def lock; end
  # end
  # mutex = Mutex.new
  # mutex.lock  # NOT FA1003: Workspace shadow
end
