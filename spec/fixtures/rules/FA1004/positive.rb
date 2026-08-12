# frozen_string_literal: true

# Positive fixtures for FA1004 - Thread thread variable detection
# These patterns should trigger findings

# Thread.current.thread_variable_get
def read_thread_var
  Thread.current.thread_variable_get(:current_user)
end

# Thread.current.thread_variable_set
def write_thread_var(value)
  Thread.current.thread_variable_set(:current_user, value)
end

# Thread instance thread_variable_get (via local variable)
def instance_read
  my_thread = Thread.current
  my_thread.thread_variable_get(:data)
end

# Thread instance thread_variable_set (via local variable)
def instance_write(value)
  my_thread = Thread.current
  my_thread.thread_variable_set(:data, value)
end
