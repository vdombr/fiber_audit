# frozen_string_literal: true

require 'json'
require 'stringio'
require 'spec_helper'
require 'fiber_audit/runtime/synchronization_graph'
require 'fiber_audit/runtime/jsonl/writer'

RSpec.describe FiberAudit::Runtime::SynchronizationGraph do
  let(:session_id) { '123e4567-e89b-42d3-a456-426614174000' }

  def build_graph(
    policy: FiberAudit::Runtime::SynchronizationGraphPolicy.new(enabled: true),
    supported: true, pid_source: -> { 700 }
  )
    io = StringIO.new
    tick = 100
    clock = FiberAudit::Runtime::Clock.new(wall: -> { Time.utc(2026, 8, 2, 12) }, monotonic: -> { tick += 1 })
    session = FiberAudit::Runtime::Session.new(
      id: session_id, started_at: Time.utc(2026, 8, 2, 12), started_monotonic_ns: 100,
      policy: FiberAudit::Runtime::Policy.new(sampling_rate: 1.0)
    )
    writer = FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: 16_384)
    recorder = FiberAudit::Runtime::Recorder.start(session: session, writer: writer, clock: clock)
    graph = described_class.new(
      policy: policy, recorder: recorder, clock: clock,
      pid_source: pid_source, supported: supported
    )
    [graph, recorder, io]
  end

  def payloads(io)
    records = io.string.lines.map do |line|
      JSON.parse(line)
    end
    records.filter_map do |record|
      record['payload'] if record['record_type'] == 'event'
    end
  end

  it 'publishes explicit state without application data' do
    disabled, recorder, io = build_graph(policy: FiberAudit::Runtime::SynchronizationGraphPolicy::DISABLED)
    expect(disabled.state).to eq(:disabled)
    expect(payloads(io).first['kind']).to eq('sync_graph_disabled')
  ensure
    disabled&.stop
    recorder&.close
  end

  it 'tracks recursive ownership, waits, releases, and opaque IDs' do
    graph, recorder, io = build_graph
    actor = Object.new
    lock = Object.new
    wait = graph.begin_wait(resource: lock, operation: 'Mutex#lock', actor: actor)
    expect(graph.acquired(resource: lock, operation: 'Mutex#lock', wait: wait, actor: actor)).to be(true)
    expect(graph.acquired(resource: lock, operation: 'Monitor#enter', actor: actor)).to be(true)
    expect(graph.snapshot.owners.values.first.depth).to eq(2)
    expect(graph.released(resource: lock, operation: 'Monitor#exit', actor: actor)).to be(true)
    expect(graph.released(resource: lock, operation: 'Mutex#unlock', actor: actor)).to be(true)
    expect(graph.snapshot.owners).to be_empty
    acquired = payloads(io).find { |payload| payload['kind'] == 'sync_acquired' }
    expect(acquired['measurements']['sync_actor_id']).not_to eq(actor.object_id)
  ensure
    graph&.stop
    recorder&.close
  end

  it 'detects a bounded cycle as evidence only' do
    graph, recorder, io = build_graph
    a = Object.new
    b = Object.new
    x = Object.new
    y = Object.new
    graph.acquired(resource: x, operation: 'Mutex#lock', actor: a)
    graph.acquired(resource: y, operation: 'Mutex#lock', actor: b)
    graph.begin_wait(resource: y, operation: 'Mutex#lock', actor: a)
    graph.begin_wait(resource: x, operation: 'Mutex#lock', actor: b)
    cycle = payloads(io).find { |payload| payload['kind'] == 'sync_cycle_candidate' }
    expect(cycle['measurements']).to include('cycle_actor_count' => 2, 'cycle_edge_count' => 4)
    expect(cycle.to_s).not_to include('deadlock')
  ensure
    graph&.stop
    recorder&.close
  end

  it 'resets inherited state when the PID changes' do
    pid = 700
    graph, recorder, = build_graph(pid_source: -> { pid })
    graph.acquired(resource: Object.new, operation: 'Mutex#lock', actor: Object.new)
    expect(graph.snapshot.owners.size).to eq(1)
    pid = 701
    expect(graph.snapshot.owners).to be_empty
    expect(graph.snapshot.identity_count).to eq(0)
  ensure
    graph&.stop
    recorder&.close
  end
end
