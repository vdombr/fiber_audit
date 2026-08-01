# frozen_string_literal: true

# Positive fixtures for FA1003 - Thread synchronization rule
# These patterns should trigger findings

class Worker
  def perform_with_mutex
    mutex = Mutex.new
    mutex.lock  # FA1003: Mutex#lock on instance
    mutex.synchronize {  # FA1003: Mutex#synchronize on instance
      critical_section
    }
  end

  def perform_with_condition_variable
    mutex = Mutex.new
    cv = ConditionVariable.new

    mutex.synchronize do
      cv.wait(mutex)  # FA1003: ConditionVariable#wait
    end
  end

  def perform_with_monitor
    monitor = Monitor.new
    monitor.synchronize {  # FA1003: Monitor#synchronize
      critical_section
    }
  end

  def perform_with_try_lock
    mutex = Mutex.new
    if mutex.try_lock  # FA1003: Mutex#try_lock (fixed :info severity)
      critical_section
    end
  end
end

# Constructor chain - should match
class QuickLock
  def initialize
    @mutex = Mutex.new
  end

  def perform
    Mutex.new.lock  # FA1003: Constructor chain Mutex.new.lock
  end
end

# Implicit synchronize via MonitorMixin
class MonitoredService
  include MonitorMixin

  def process
    synchronize {  # FA1003: Implicit MonitorMixin#synchronize
      critical_section
    }
  end

  def another_method
    synchronize do  # FA1003: Implicit MonitorMixin#synchronize
      do_work
    end
  end
end
