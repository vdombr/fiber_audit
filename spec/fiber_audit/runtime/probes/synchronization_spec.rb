# frozen_string_literal: true

require_relative '../../../support/runtime_probe_harness'

RSpec.describe FiberAudit::Runtime::Probes::Synchronization do
  after { stop_probe_runtime(@runtime) if @runtime }

  def synchronized_nonlocal_return(mutex)
    mutex.synchronize { return :returned }
    :unreachable
  end

  it 'preserves mutex blocks and reports only Boolean try-lock measurements' do
    @runtime = start_probe_runtime
    mutex = Mutex.new
    sentinel = Object.new

    expect(mutex.synchronize { sentinel }).to equal(sentinel)
    expect(mutex.try_lock).to be(true)
    mutex.unlock

    try_event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'Mutex#try_lock' }
    expect(try_event.dig('payload', 'measurements')).to include(
      'acquired' => true,
      'contention_observed' => false
    )
  end

  it 'observes contention without inspecting lock state before the call' do
    @runtime = start_probe_runtime
    mutex = Mutex.new
    acquired = Queue.new
    release = Queue.new
    owner = Thread.new do
      mutex.lock
      acquired << true
      release.pop
      mutex.unlock
    end
    acquired.pop

    expect(mutex.try_lock).to be(false)
    release << true
    owner.join

    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'Mutex#try_lock' }
    expect(event.dig('payload', 'measurements')).to include(
      'acquired' => false,
      'contention_observed' => true
    )
  end

  it 'preserves condition-variable wait arguments and return value' do
    @runtime = start_probe_runtime
    mutex = Mutex.new
    condition = ConditionVariable.new

    returned = mutex.synchronize { condition.wait(mutex, 0.001) }

    expect(returned).to be_nil
    expect(operations(@runtime)).to include('ConditionVariable#wait')
  end

  it 'installs Monitor and MonitorMixin hooks without duplicate operations' do
    @runtime = start_probe_runtime
    require 'monitor'
    @runtime.registry.scan!
    monitor = Monitor.new
    mixin_class = Class.new do
      include MonitorMixin
    end

    expect(monitor.synchronize { :monitor }).to eq(:monitor)
    expect(mixin_class.new.synchronize { :mixin }).to eq(:mixin)

    observed = operations(@runtime)
    expect(observed.count('Monitor#synchronize')).to eq(1)
    expect(observed.count('MonitorMixin#synchronize')).to eq(1)
  end

  it 'preserves non-local block control flow' do
    @runtime = start_probe_runtime

    expect(synchronized_nonlocal_return(Mutex.new)).to eq(:returned)
    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'Mutex#synchronize' }
    expect(event.dig('payload', 'kind')).to eq('operation_aborted')
  end

  it 're-raises block exceptions unchanged and never stores their messages' do
    @runtime = start_probe_runtime
    error = Class.new(StandardError).new('mutex-stage5-secret')

    expect do
      Mutex.new.synchronize { raise error }
    end.to(raise_error { |raised| expect(raised).to equal(error) })

    expect(@runtime.io.string).not_to include('mutex-stage5-secret')
  end
end
