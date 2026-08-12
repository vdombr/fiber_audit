# frozen_string_literal: true

# Positive fixture for FA1001 - Subprocess lifecycle operations
# These patterns should be detected by the rule.

class SubprocessExamples
  def explicit_kernel_calls
    Kernel.system('ls')
    Kernel.exec('pwd')
    Kernel.spawn('echo', 'hello')
  end

  def bare_kernel_calls
    system('ls')
    exec('pwd')
    spawn('echo', 'hello')
  end

  def open3_calls
    Open3.capture2('ls')
    Open3.capture2e('ls')
    Open3.capture3('ls')
    Open3.pipeline('ls', 'grep')
  end

  def io_popen
    IO.popen('ls')
  end

  def process_creation
    Process.spawn('ls')
  end

  def process_replacement
    Process.exec('pwd')
  end

  def process_waiting
    Process.wait(1234)
    Process.wait2(1234)
    Process.waitpid(1234)
    Process.waitpid2(1234)
    Process.waitall
    Process::Status.wait(1234)
  end

  def process_detach
    Process.detach(1234)
  end
end
