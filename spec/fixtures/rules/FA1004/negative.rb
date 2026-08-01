# frozen_string_literal: true

# Negative fixtures for FA1004 - Thread-local state detection
# These patterns should NOT trigger findings

# ActiveSupport::CurrentAttributes (deferred)
def use_current_attributes
  ActiveSupport::CurrentAttributes[:current_user]
end

# Arbitrary methods on Thread.current (not thread_variable_* or []/[]=)
def arbitrary_method
  Thread.current.object_id
end

# Direct Thread class calls (not instance methods)
def direct_thread_call
  Thread.new { puts 'hello' }
end

# Thread class method calls
def thread_class_method
  Thread.list
end

# Regular local variable (not Thread)
def regular_variable
  my_var = {}
  my_var[:key]
end

# Fiber-local variables (not thread-local)
def fiber_local
  Fiber.current[:data]
end
