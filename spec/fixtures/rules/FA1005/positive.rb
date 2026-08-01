# frozen_string_literal: true

# Positive fixture for FA1005 - Explicit IO.select calls
# These patterns should be detected by the rule.

class IOSelectExamples
  def explicit_io_select
    IO.select([read_io], nil, nil, 5)
  end

  def explicit_kernel_select
    Kernel.select([read_io], nil, nil, 5)
  end

  def bare_select_call
    select([read_io], nil, nil, 5)
  end

  def select_in_loop
    loop do
      IO.select([read_io])
    end
  end
end
