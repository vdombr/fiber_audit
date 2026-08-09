# frozen_string_literal: true

require 'stringio'
require 'fiber_audit/runtime/probes/registry'

RSpec.describe FiberAudit::Runtime::Probes::Registry do
  let(:session_id) { '123e4567-e89b-42d3-a456-426614174000' }

  def build_base
    policy = FiberAudit::Runtime::Policy.new(sampling_rate: 1.0)
    io = StringIO.new
    clock = FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12) },
      monotonic: -> { 100 }
    )
    session = FiberAudit::Runtime::Session.new(
      id: session_id,
      started_at: Time.utc(2026, 8, 2, 12),
      started_monotonic_ns: 1,
      policy: policy
    )
    writer = FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: policy.max_record_bytes)
    recorder = FiberAudit::Runtime::Recorder.start(session: session, writer: writer, clock: clock, random: -> { 0.0 })
    base = FiberAudit::Runtime::Probes::Base.new(
      recorder: recorder,
      clock: clock,
      redactor: FiberAudit::Runtime::Redactor.new(root: Dir.pwd, policy: policy),
      active_operations: FiberAudit::Runtime::ActiveOperations.new
    )
    [base, recorder]
  end

  after do
    described_class.deactivate(@registry) if @registry
  end

  it 'installs every available wrapper at most once' do
    base, recorder = build_base
    @registry = described_class.activate(base: base)

    2.times { @registry.scan! }

    expect(Kernel.ancestors.count(FiberAudit::Runtime::Probes::Subprocess::KernelInstanceHook)).to eq(1)
    expect(Thread.ancestors.count(FiberAudit::Runtime::Probes::ThreadWait::Hook)).to eq(1)
    expect(Mutex.ancestors.count(FiberAudit::Runtime::Probes::Synchronization::MutexHook)).to eq(1)
    expect(IO.singleton_class.ancestors.count(FiberAudit::Runtime::Probes::IOSelect::IOHook)).to eq(1)
    expect(Kernel.private_instance_methods).to include(:require, :system, :exec, :spawn, :select)
    recorder.close
  end

  it 'deactivates irreversibly prepended wrappers without changing application behavior' do
    base, recorder = build_base
    @registry = described_class.activate(base: base)
    described_class.deactivate(@registry)
    mutex = Mutex.new
    result = Object.new

    expect(mutex.synchronize { result }).to equal(result)
    expect(described_class.current).to be_nil
    recorder.close
  end

  it 'preserves require Boolean results and exceptions' do
    base, recorder = build_base
    @registry = described_class.activate(base: base)

    expect(require('json')).to be(false)
    error = nil
    begin
      require 'fiber_audit_stage5_missing_feature'
    rescue LoadError => e
      error = e
    end

    expect(error).to be_a(LoadError)
    recorder.close
  end

  it 'validates activation and observation blocks' do
    expect { described_class.activate(base: Object.new) }
      .to raise_error(FiberAudit::RuntimeContractError, /base/)
    expect { described_class.observe(operation: 'Mutex#lock') }
      .to raise_error(ArgumentError, /requires a block/)
  end
end
