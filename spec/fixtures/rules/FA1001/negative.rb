# frozen_string_literal: true

# Negative fixture for FA1001 - Patterns that should NOT be detected

class NegativeSubprocessExamples
  def wrong_receivers
    MyKernel.system('ls')
    CustomOpen3.capture2('ls')
    MyIO.popen('ls')
  end

  def wrong_methods
    Kernel.other_method
    Open3.custom_method
    IO.custom_method
    Process.custom_method
  end

  def safe_calls
    puts('hello')
    File.read('test.txt')
    sleep(1)
  end
end

module ShadowedSubprocessExample
  class Kernel
    def self.system(command)
      puts "Custom system: #{command}"
    end
  end

  class Caller
    def call
      Kernel.system('ls')
    end
  end
end
