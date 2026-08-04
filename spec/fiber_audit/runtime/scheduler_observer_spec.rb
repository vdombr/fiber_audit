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

  after do
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

  it 'requires a watchdog owned by FiberAudit' do
    expect { described_class.activate(watchdog: Object.new) }
      .to raise_error(FiberAudit::RuntimeContractError, /watchdog/)
  end
end
