# frozen_string_literal: true

# Negative fixture for FA1001 - Patterns that should NOT be detected

class Kernel
  # This is a semantic shadow - a custom Kernel class in the workspace
  # Calls to this should NOT be detected as blocking
  def self.system(cmd)
    puts "Custom system: #{cmd}"
  end
end

class NegativeExamples
  def wrong_receivers
    # These have the right method names but wrong receivers
    MyKernel.system('ls')
    CustomOpen3.capture2('ls')
    MyIO.popen('ls')
  end

  def wrong_methods
    # These have the right receivers but wrong methods
    Kernel.other_method
    Open3.custom_method
    IO.custom_method
    Process.custom_method
  end

  def safe_calls
    # These are completely unrelated
    puts('hello')
    File.read('test.txt')
    sleep(1)
  end

  def semantic_shadow_call
    # This calls the custom Kernel defined above
    Kernel.system('ls')
  end
end
