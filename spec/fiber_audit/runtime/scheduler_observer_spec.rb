# frozen_string_literal: true

require 'fiber_audit/runtime/scheduler_observer'

RSpec.describe FiberAudit::Runtime::SchedulerObserver do
  let(:policy) { FiberAudit::Runtime::Policy.new }
  let(:watchdog) do
    FiberAudit::Runtime::Watchdog.allocate.tap do |instance|
      allow(instance).to receive(:enabled?).and_return(true)
      allow(instance).to receive(:policy).and_return(policy)
      allow(instance).to receive(:fail_open?).and_return(true)
      allow(instance).to receive(:scheduler_installed).and_return(instance)
      allow(instance).to receive(:scheduler_closing).and_return(instance)
      allow(instance).to receive(:scheduler_unsupported).and_return(instance)
    end
  end

  let(:valid_scheduler_class) do
    Class.new do
      define_method(:block) { |*| nil }
      define_method(:unblock) { |*| nil }
      define_method(:kernel_sleep) { |*| nil }
      define_method(:io_wait) { |*| nil }
      define_method(:close) { :closed }
    end
  end

  after do
    Fiber.set_scheduler(nil) if Fiber.scheduler
    described_class.deactivate(@observer) if @observer
  end

  it 'installs an idempotent scheduler close hook and preserves close results' do
    scheduler_class = Class.new do
      def close
        :application_result
      end
    end
    scheduler = scheduler_class.new
    @observer = described_class.activate(watchdog: watchdog)

    2.times { @observer.scheduler_installed(scheduler: scheduler, thread: Thread.current) }

    expect(scheduler.singleton_class.ancestors.count(described_class::SchedulerCloseHook)).to eq(1)
    expect(scheduler.close).to eq(:application_result)
    expect(watchdog).to have_received(:scheduler_closing).with(thread: Thread.current)
  end

  it 'becomes inert after deactivation' do
    scheduler = Class.new { def close = :closed }.new
    @observer = described_class.activate(watchdog: watchdog)
    @observer.scheduler_installed(scheduler: scheduler, thread: Thread.current)
    described_class.deactivate(@observer)

    scheduler.close

    expect(watchdog).not_to have_received(:scheduler_closing)
  end

  it 'marks schedulers unsupported when a close hook cannot be installed' do
    scheduler = Object.new
    scheduler.freeze
    @observer = described_class.activate(watchdog: watchdog)

    expect do
      @observer.scheduler_installed(scheduler: scheduler, thread: Thread.current)
    end.not_to raise_error
    expect(watchdog).to have_received(:scheduler_unsupported).with(thread: Thread.current)
    expect(watchdog).not_to have_received(:scheduler_installed)
  end

  it 'does not use an observer inherited by a different process' do
    @observer = described_class.activate(watchdog: watchdog)
    allow(@observer).to receive(:active_for_current_process?).and_return(false)
    scheduler = Class.new { def close = :closed }.new
    scheduler.singleton_class.prepend(described_class::SchedulerCloseHook)

    scheduler.close

    expect(watchdog).not_to have_received(:scheduler_closing)
  end

  it 'keeps the accepted scheduler active when a replacement is rejected' do
    scheduler = valid_scheduler_class.new
    @observer = described_class.activate(watchdog: watchdog)
    Fiber.set_scheduler(scheduler)

    expect { Fiber.set_scheduler(Object.new) }.to raise_error(ArgumentError)

    expect(Fiber.scheduler).to equal(scheduler)
    expect(watchdog).not_to have_received(:scheduler_closing)
    expect(watchdog).to have_received(:scheduler_installed).once.with(thread: Thread.current)
  end

  it 'reconciles a successful scheduler replacement exactly once' do
    previous = valid_scheduler_class.new
    replacement = valid_scheduler_class.new
    @observer = described_class.activate(watchdog: watchdog)
    Fiber.set_scheduler(previous)

    expect(Fiber.set_scheduler(replacement)).to equal(replacement)

    expect(Fiber.scheduler).to equal(replacement)
    expect(watchdog).to have_received(:scheduler_closing).once.with(thread: Thread.current)
    expect(watchdog).to have_received(:scheduler_installed).twice.with(thread: Thread.current)
  end

  it 'reinstalls observation when Ruby closes and accepts the same scheduler' do
    scheduler = valid_scheduler_class.new
    @observer = described_class.activate(watchdog: watchdog)
    Fiber.set_scheduler(scheduler)

    Fiber.set_scheduler(scheduler)

    expect(Fiber.scheduler).to equal(scheduler)
    expect(watchdog).to have_received(:scheduler_closing).once.with(thread: Thread.current)
    expect(watchdog).to have_received(:scheduler_installed).twice.with(thread: Thread.current)
  end

  it 'reconciles removal after Ruby accepts nil' do
    scheduler = valid_scheduler_class.new
    @observer = described_class.activate(watchdog: watchdog)
    Fiber.set_scheduler(scheduler)

    expect(Fiber.set_scheduler(nil)).to be_nil

    expect(Fiber.scheduler).to be_nil
    expect(watchdog).to have_received(:scheduler_closing).once.with(thread: Thread.current)
  end

  it 'announces closure before calling the scheduler so its heartbeat can stop' do
    scheduler_class = Class.new(valid_scheduler_class) do
      define_method(:close) { raise 'close failed' }
    end
    scheduler = scheduler_class.new
    @observer = described_class.activate(watchdog: watchdog)
    Fiber.set_scheduler(scheduler)

    expect { Fiber.set_scheduler(nil) }.to raise_error(RuntimeError, 'close failed')

    expect(watchdog).to have_received(:scheduler_closing).once.with(thread: Thread.current)
  end

  it 'requires a watchdog owned by FiberAudit' do
    expect { described_class.activate(watchdog: Object.new) }
      .to raise_error(FiberAudit::RuntimeContractError, /watchdog/)
  end
end
