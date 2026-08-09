# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'FiberAudit runtime foundation loader' do
  it 'loads every public runtime contract independently' do
    script = <<~RUBY
      require 'fiber_audit/runtime'
      constants = [
        FiberAudit::Runtime::Policy,
        FiberAudit::Runtime::WatchdogPolicy,
        FiberAudit::Runtime::Location,
        FiberAudit::Runtime::Event,
        FiberAudit::Runtime::Session,
        FiberAudit::Runtime::SessionSummary,
        FiberAudit::Runtime::Redactor,
        FiberAudit::Runtime::Clock,
        FiberAudit::Runtime::Sampler,
        FiberAudit::Runtime::Limits,
        FiberAudit::Runtime::JSONL::Schema,
        FiberAudit::Runtime::JSONL::Writer,
        FiberAudit::Runtime::Recorder,
        FiberAudit::Runtime::Environment,
        FiberAudit::Runtime::ActiveOperations,
        FiberAudit::Runtime::Heartbeat,
        FiberAudit::Runtime::Watchdog,
        FiberAudit::Runtime::SchedulerObserver,
        FiberAudit::Runtime::Probes::Base,
        FiberAudit::Runtime::Probes::Registry,
        FiberAudit::Runtime::Probes::Subprocess,
        FiberAudit::Runtime::Probes::ThreadWait,
        FiberAudit::Runtime::Probes::Synchronization,
        FiberAudit::Runtime::Probes::ThreadState,
        FiberAudit::Runtime::Probes::IOSelect,
        FiberAudit::Runtime::Probes::Socket,
        FiberAudit::Runtime::Probes::HTTP,
        FiberAudit::Runtime::Lifecycle,
        FiberAudit::Runtime::Supervisor,
        FiberAudit::RuntimeContractError,
        FiberAudit::RuntimeSafetyError
      ]
      puts constants.size
    RUBY
    output, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script)
    expect(status).to be_success, stderr
    expect(output.strip).to eq('31')
  end

  it 'does not load static analysis or framework dependencies' do
    script = <<~RUBY
      thread_count = Thread.list.size
      require 'fiber_audit/runtime'
      prohibited = %w[Prism Rubydex Rails Async Falcon]
      puts prohibited.any? { |name| Object.const_defined?(name, false) }
      puts defined?(FiberAudit::Static).nil?
      puts defined?(FiberAudit::Runtime::Boot).nil?
      puts !defined?(FiberAudit::Runtime::Probes).nil?
      puts !Fiber.singleton_class.ancestors.include?(FiberAudit::Runtime::SchedulerObserver::FiberHook)
      puts !Kernel.ancestors.include?(FiberAudit::Runtime::Probes::Registry::RequireInstanceHook)
      puts !Mutex.ancestors.include?(FiberAudit::Runtime::Probes::Synchronization::MutexHook)
      puts Thread.list.size == thread_count
    RUBY
    output, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script)
    expect(status).to be_success, stderr
    expect(output.lines.map(&:strip)).to eq(%w[false true true true true true true true])
  end
end
