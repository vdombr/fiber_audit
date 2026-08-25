# frozen_string_literal: true

require 'fiber_audit/runtime/scheduler_snapshot'

RSpec.describe FiberAudit::Runtime::SchedulerSnapshot do
  describe '.new' do
    it 'creates an immutable ten-field tri-state snapshot' do
      snapshot = described_class.new(
        scheduler_present: true,
        fiber_blocking: false
      )

      expect(snapshot.scheduler_present).to be(true)
      expect(snapshot.fiber_blocking).to be(false)
      expect(snapshot.scheduler_io_select_supported).to be_nil
      expect(snapshot.scheduler_process_wait_supported).to be_nil
      expect(snapshot.scheduler_address_resolve_supported).to be_nil
      expect(snapshot).to be_frozen
    end

    it 'accepts optional boolean capability fields' do
      snapshot = described_class.new(
        scheduler_present: true,
        fiber_blocking: false,
        scheduler_io_select_supported: true,
        scheduler_process_wait_supported: false,
        scheduler_address_resolve_supported: true
      )

      expect(snapshot.scheduler_io_select_supported).to be(true)
      expect(snapshot.scheduler_process_wait_supported).to be(false)
      expect(snapshot.scheduler_address_resolve_supported).to be(true)
    end

    it 'accepts nil for unknown scheduler and Fiber state' do
      snapshot = described_class.new(scheduler_present: nil, fiber_blocking: nil)

      expect(snapshot.scheduler_present).to be_nil
      expect(snapshot.fiber_blocking).to be_nil
    end

    it 'rejects non-boolean/non-nil required state fields' do
      expect do
        described_class.new(scheduler_present: 'yes', fiber_blocking: false)
      end.to raise_error(FiberAudit::RuntimeContractError, /scheduler_present must be a Boolean or nil/)

      expect do
        described_class.new(scheduler_present: true, fiber_blocking: 1)
      end.to raise_error(FiberAudit::RuntimeContractError, /fiber_blocking must be a Boolean or nil/)
    end

    it 'rejects non-boolean/non-nil optional fields' do
      expect do
        described_class.new(
          scheduler_present: true,
          fiber_blocking: false,
          scheduler_io_select_supported: 'yes'
        )
      end.to raise_error(FiberAudit::RuntimeContractError, /scheduler_io_select_supported must be a Boolean or nil/)
    end

    it 'rejects integer values for capability fields' do
      expect do
        described_class.new(
          scheduler_present: true,
          fiber_blocking: false,
          scheduler_process_wait_supported: 1
        )
      end.to raise_error(FiberAudit::RuntimeContractError, /scheduler_process_wait_supported must be a Boolean or nil/)
    end
  end

  describe '#to_measurements' do
    it 'returns a frozen hash with symbol keys' do
      snapshot = described_class.new(
        scheduler_present: true,
        fiber_blocking: false,
        scheduler_io_select_supported: true,
        scheduler_process_wait_supported: false,
        scheduler_address_resolve_supported: nil
      )

      measurements = snapshot.to_measurements

      expect(measurements).to be_a(Hash)
      expect(measurements).to be_frozen
      expect(measurements.keys).to all(be_a(Symbol))
      expect(measurements[:scheduler_present]).to be(true)
      expect(measurements[:fiber_blocking]).to be(false)
      expect(measurements[:scheduler_io_select_supported]).to be(true)
      expect(measurements[:scheduler_process_wait_supported]).to be(false)
      expect(measurements[:scheduler_address_resolve_supported]).to be_nil
    end

    it 'includes all ten scheduler metadata fields' do
      snapshot = described_class.new(scheduler_present: false, fiber_blocking: true)
      measurements = snapshot.to_measurements

      expect(measurements.keys).to contain_exactly(
        :scheduler_present, :current_scheduler_present, :scheduler_snapshot_consistent, :fiber_blocking,
        :scheduler_block_supported, :scheduler_kernel_sleep_supported, :scheduler_io_wait_supported,
        :scheduler_io_select_supported, :scheduler_process_wait_supported, :scheduler_address_resolve_supported
      )
    end
  end
end

RSpec.describe FiberAudit::Runtime::SchedulerSnapshotCapture do
  def scheduler_class(*optional_hooks)
    Class.new do
      define_method(:block) { |*| nil }
      define_method(:unblock) { |*| nil }
      define_method(:kernel_sleep) { |*| nil }
      define_method(:io_wait) { |*| nil }
      define_method(:close) { nil }
      optional_hooks.each { |hook| define_method(hook) { |*| nil } }
    end
  end

  describe '.capture' do
    it 'returns a SchedulerSnapshot' do
      snapshot = described_class.capture
      expect(snapshot).to be_a(FiberAudit::Runtime::SchedulerSnapshot)
      expect(snapshot).to be_frozen
    end

    it 'captures blocking and non-blocking Fiber state exactly' do
      blocking = Fiber.new(blocking: true) { described_class.capture.fiber_blocking }
      non_blocking = Fiber.new(blocking: false) { described_class.capture.fiber_blocking }

      expect(blocking.resume).to be(true)
      expect(non_blocking.resume).to be(false)
    end

    it 'detects absence of scheduler in test context' do
      # Ensure no scheduler is installed
      old_scheduler = Fiber.scheduler
      Fiber.set_scheduler(nil) if old_scheduler

      begin
        snapshot = described_class.capture
        expect(snapshot.scheduler_present).to be(false)
        expect(snapshot.scheduler_io_select_supported).to be_nil
        expect(snapshot.scheduler_process_wait_supported).to be_nil
        expect(snapshot.scheduler_address_resolve_supported).to be_nil
      ensure
        Fiber.set_scheduler(old_scheduler) if old_scheduler
      end
    end

    it 'detects scheduler capabilities when present' do
      scheduler = scheduler_class(:io_select, :address_resolve).new
      Fiber.set_scheduler(scheduler)

      snapshot = described_class.capture
      expect(snapshot.scheduler_present).to be(true)
      expect(snapshot.scheduler_io_select_supported).to be(true)
      expect(snapshot.scheduler_process_wait_supported).to be(false)
      expect(snapshot.scheduler_address_resolve_supported).to be(true)
    ensure
      Fiber.set_scheduler(nil) if Fiber.scheduler
    end

    it 'reports unsupported optional hooks as false on an installed scheduler' do
      scheduler = scheduler_class.new
      Fiber.set_scheduler(scheduler)

      snapshot = described_class.capture
      expect(snapshot.scheduler_present).to be(true)
      expect(snapshot.scheduler_io_select_supported).to be(false)
      expect(snapshot.scheduler_process_wait_supported).to be(false)
      expect(snapshot.scheduler_address_resolve_supported).to be(false)
    ensure
      Fiber.set_scheduler(nil) if Fiber.scheduler
    end

    it 'fails open with unknown state instead of false facts' do
      allow(Fiber).to receive(:scheduler).and_raise(StandardError, 'test error')

      snapshot = described_class.capture
      expect(snapshot.to_measurements.values).to all(be_nil)
    end

    it 'is deterministic for the same execution context' do
      snapshot1 = described_class.capture
      snapshot2 = described_class.capture

      # Same fiber, same scheduler state
      expect(snapshot1.scheduler_present).to eq(snapshot2.scheduler_present)
      expect(snapshot1.fiber_blocking).to eq(snapshot2.fiber_blocking)
    end
  end
end
