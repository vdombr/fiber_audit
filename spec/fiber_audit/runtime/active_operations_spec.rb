# frozen_string_literal: true

require 'fiber_audit/runtime/active_operations'

RSpec.describe FiberAudit::Runtime::ActiveOperations do
  let(:location) { FiberAudit::Runtime::Location.new(path: 'app/jobs/task.rb', line: 7, column: 2) }

  def register(registry, operation: 'Mutex#lock', thread: Thread.current, fiber: Fiber.current)
    registry.register(
      operation: operation,
      location: location,
      execution_context: :job,
      monotonic_ns: 100,
      thread: thread,
      fiber: fiber
    )
  end

  it 'registers nested operations with immutable sequence-ordered snapshots' do
    registry = described_class.new
    first = register(registry)
    second = register(registry, operation: 'Thread#join')

    snapshot = registry.snapshot

    expect(snapshot.map(&:sequence)).to eq([first.sequence, second.sequence])
    expect(snapshot.map(&:operation)).to eq(%w[Mutex#lock Thread#join])
    expect(snapshot).to be_frozen
    expect(snapshot).to all(be_frozen)
  end

  it 'finishes handles idempotently without accepting stale values' do
    registry = described_class.new
    handle = register(registry)

    expect(registry.finish(handle).operation).to eq('Mutex#lock')
    expect(registry.finish(handle)).to be_nil
    expect(registry.finish(Object.new)).to be_nil
    expect(registry).to have_attributes(size: 0)
  end

  it 'isolates snapshots by ephemeral thread identity' do
    registry = described_class.new
    thread_one = Object.new
    thread_two = Object.new
    register(registry, thread: thread_one)
    register(registry, thread: thread_two)

    expect(registry.snapshot(thread_id: thread_one.object_id).map(&:thread_id)).to eq([thread_one.object_id])
    expect(registry.snapshot(thread_id: thread_two.object_id).map(&:thread_id)).to eq([thread_two.object_id])
  end

  it 'bounds capacity and snapshot size without blocking' do
    registry = described_class.new(capacity: 2, snapshot_limit: 1)

    expect(register(registry)).to be_a(described_class::Handle)
    expect(register(registry)).to be_a(described_class::Handle)
    expect(register(registry)).to be_nil
    expect(registry.snapshot.size).to eq(1)
    expect(registry.size).to eq(2)
  end

  it 'assigns unique contiguous sequences under concurrency' do
    registry = described_class.new
    handles = 20.times.map { Thread.new { register(registry) } }.map(&:value)

    expect(handles.map(&:sequence).sort).to eq((1..20).to_a)
  end

  it 'resets before touching inherited synchronization after a PID change' do
    pid = 100
    registry = described_class.new(pid_source: -> { pid })
    parent = register(registry)
    pid = 101

    expect(registry.snapshot).to be_empty
    child = register(registry)

    expect(child.pid).to eq(101)
    expect(child.sequence).to eq(1)
    expect(registry.finish(parent)).to be_nil
  end

  it 'rejects noncanonical or unbounded operation data' do
    registry = described_class.new

    expect { register(registry, operation: 'contains secret arguments') }
      .to raise_error(FiberAudit::RuntimeContractError, /operation/)
    expect do
      registry.register(
        operation: 'Mutex#lock',
        location: {},
        execution_context: :job,
        monotonic_ns: 1
      )
    end.to raise_error(FiberAudit::RuntimeContractError, /location/)
  end
end
