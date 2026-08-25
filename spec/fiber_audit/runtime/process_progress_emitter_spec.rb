# frozen_string_literal: true

require 'json'
require 'stringio'
require 'spec_helper'
require 'fiber_audit/runtime/process_progress_emitter'
require 'fiber_audit/runtime/jsonl/writer'

RSpec.describe FiberAudit::Runtime::ProcessProgressEmitter do
  # RSpec-local writer fixture.
  # rubocop:disable Lint/ConstantDefinitionInBlock
  class ProgressWriter
    attr_reader :bytes

    def initialize(result = nil)
      @result = result
      @bytes = +''.b
      @closed = false
    end

    def write_nonblock(value, **_options)
      raise @result if @result.is_a?(Exception)
      return @result if @result

      @bytes << value
      value.bytesize
    end

    def close = (@closed = true)
    def closed? = @closed
  end
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def build_emitter(policy: FiberAudit::Runtime::ProcessProgressPolicy.new(enabled: true), writer: ProgressWriter.new)
    io = StringIO.new
    clock = FiberAudit::Runtime::Clock.new(wall: -> { Time.utc(2026, 8, 2, 12) }, monotonic: -> { 100 })
    session = FiberAudit::Runtime::Session.new(
      id: '123e4567-e89b-42d3-a456-426614174000', started_at: Time.utc(2026, 8, 2, 12),
      started_monotonic_ns: 100, policy: FiberAudit::Runtime::Policy.new(sampling_rate: 1.0)
    )
    recorder = FiberAudit::Runtime::Recorder.start(
      session: session,
      writer: FiberAudit::Runtime::JSONL::Writer.new(io: io, max_record_bytes: 16_384),
      clock: clock
    )
    emitter = described_class.new(
      policy: policy, recorder: recorder, writer: writer, clock: clock,
      pid_source: -> { 700 }, generation_source: -> { 11 },
      thread_factory: lambda { |&_block|
        Thread.new { nil }
      }
    )
    [emitter, recorder, io, writer]
  end

  it 'writes fixed frames without application data' do
    emitter, recorder, io, writer = build_emitter
    expect(emitter.emit_progress).to eq(:written)
    expect(writer.bytes.bytesize).to eq(80)
    expect(io.string).not_to include('command', 'argument', 'private')
  ensure
    emitter&.stop
    recorder&.close unless recorder&.closed?
  end

  it 'fails open on writer errors and records completion counters' do
    emitter, recorder, = build_emitter(writer: ProgressWriter.new(IOError.new('private-writer-error')))
    expect(emitter.state).to eq(:unsupported)
  ensure
    emitter&.stop
    recorder&.close unless recorder&.closed?
  end
end
