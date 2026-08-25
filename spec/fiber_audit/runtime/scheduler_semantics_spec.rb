# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'

RSpec.describe 'supported Ruby scheduler semantics' do
  let(:script) { File.expand_path('../../../script/scheduler-semantics', __dir__) }

  def run_semantics
    stdin = stdout = stderr = wait_thread = nil
    output_reader = error_reader = nil
    stdin, stdout, stderr, wait_thread = Open3.popen3(RbConfig.ruby, script)
    stdin.close
    output_reader = Thread.new { stdout.read }
    error_reader = Thread.new { stderr.read }
    status = Timeout.timeout(20) { wait_thread.value }
    [output_reader.value, error_reader.value, status]
  rescue Timeout::Error
    begin
      Process.kill('KILL', wait_thread.pid) if wait_thread
    rescue Errno::ESRCH
      nil
    end
    wait_thread&.value
    raise
  ensure
    [stdin, stdout, stderr].compact.each do |io|
      io.close unless io.closed?
    rescue IOError
      nil
    end
    output_reader&.kill
    error_reader&.kill
  end

  it 'reproduces only scheduler capabilities consumed by FiberAudit' do
    stdout, stderr, status = run_semantics

    expect(stderr).to eq('')
    expect(status).to be_success
    result = JSON.parse(stdout)
    expect(result).to include(
      'fiber_blocking_state' => {
        'blocking' => true,
        'nonblocking' => false
      },
      'thread_join' => 'block',
      'thread_value' => 'block',
      'mutex_lock' => 'block',
      'mutex_synchronize' => 'block',
      'mutex_try_lock' => nil,
      'condition_variable_wait' => 'kernel_sleep',
      'monitor_synchronize' => 'block',
      'io_select' => 'io_select',
      'address_resolution' => 'address_resolve',
      'storage' => {
        'thread_index' => nil,
        'thread_variable' => 'parent_thread',
        'fiber_storage' => 'inherited_storage'
      },
      'rejected_scheduler_replacement' => { 'raised' => true, 'retained' => true }
    )
    expect(result.fetch('process_wait')).to eq(
      'wait' => 'process_wait',
      'wait2' => 'process_wait',
      'waitpid' => 'process_wait',
      'waitpid2' => 'process_wait',
      'waitall' => 'process_wait',
      'status_wait' => 'process_wait'
    )
  end

  it 'checks current-scheduler visibility without assuming unsupported APIs' do
    stdout, stderr, status = run_semantics

    expect(stderr).to eq('')
    expect(status).to be_success
    state = JSON.parse(stdout).fetch('current_scheduler_state')
    if Fiber.respond_to?(:current_scheduler)
      expect(state).to eq(
        'api_supported' => true,
        'scheduler_present' => true,
        'blocking_current_present' => false,
        'nonblocking_current_equal' => true
      )
    else
      expect(state).to eq(
        'api_supported' => false,
        'scheduler_present' => true,
        'blocking_current_present' => nil,
        'nonblocking_current_equal' => nil
      )
    end
  end

  it 'behaviorally checks Ruby 4 IO-close interruption with an explicit version guard' do
    stdout, _stderr, status = run_semantics
    expect(status).to be_success
    interrupt = JSON.parse(stdout).fetch('fiber_interrupt')

    if RUBY_VERSION.split('.').first.to_i >= 4
      expect(interrupt).to eq(
        'supported' => true,
        'hook_called' => true,
        'exception' => 'IOError',
        'result' => 'io_error'
      )
    else
      expect(interrupt).to eq('supported' => false, 'skipped' => true)
    end
  end
end
