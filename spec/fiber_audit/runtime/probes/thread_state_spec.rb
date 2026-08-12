# frozen_string_literal: true

require_relative '../../../support/runtime_probe_harness'

RSpec.describe FiberAudit::Runtime::Probes::ThreadState do
  after do
    Thread.current[:fiber_audit_stage5_key] = nil
    Thread.current.thread_variable_set(:fiber_audit_stage5_variable, nil)
    stop_probe_runtime(@runtime) if @runtime
  end

  it 'preserves Thread.current index values without observation or retaining keys or values' do
    @runtime = start_probe_runtime
    value = Object.new
    thread_variables_before = Thread.current.thread_variables

    expect(Thread.current[:fiber_audit_stage5_key] = value).to equal(value)
    expect(Thread.current[:fiber_audit_stage5_key]).to equal(value)

    # Thread.current index access is not observed after v0.3 alignment
    expect(operations(@runtime)).to eq([])
    expect(Thread.current.thread_variables).to eq(thread_variables_before)
    expect(@runtime.io.string).not_to include('fiber_audit_stage5_key')
  end

  it 'does not report index access on a different Thread object' do
    @runtime = start_probe_runtime
    thread = Thread.new { sleep 0.01 }

    thread[:fiber_audit_other_thread_secret] = 'secret-value'
    expect(thread[:fiber_audit_other_thread_secret]).to eq('secret-value')
    thread.join

    expect(operations(@runtime)).not_to include('Thread.current.[]', 'Thread.current.[]=')
    expect(@runtime.io.string).not_to include('fiber_audit_other_thread_secret', 'secret-value')
  end

  it 'preserves thread-variable values on any Thread instance' do
    @runtime = start_probe_runtime
    value = Object.new

    expect(Thread.current.thread_variable_set(:fiber_audit_stage5_variable, value)).to equal(value)
    expect(Thread.current.thread_variable_get(:fiber_audit_stage5_variable)).to equal(value)

    expect(operations(@runtime)).to eq(%w[Thread.thread_variable_set Thread.thread_variable_get])
    expect(@runtime.io.string).not_to include('fiber_audit_stage5_variable')
  end
end
