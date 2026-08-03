# frozen_string_literal: true

require 'json'
require 'stringio'
require 'tmpdir'
require 'fiber_audit/runtime/jsonl/writer'

RSpec.describe FiberAudit::Runtime::JSONL::Writer do
  let(:session) do
    FiberAudit::Runtime::Session.new(
      id: '123e4567-e89b-42d3-a456-426614174000',
      started_at: Time.utc(2026, 8, 2, 12),
      started_monotonic_ns: 100
    )
  end
  let(:record) { FiberAudit::Runtime::JSONL::Schema.start_record(session) }
  let(:event_record) do
    event = FiberAudit::Runtime::Event.new(
      kind: :operation_completed,
      source: :instrumentation,
      occurred_at: Time.utc(2026, 8, 2, 12, 0, 1),
      monotonic_ns: 200,
      operation: 'Mutex#lock'
    )
    FiberAudit::Runtime::JSONL::Schema.event_record(
      session_id: session.id,
      sequence: 1,
      event: event
    )
  end
  let(:short_write_io_class) do
    Class.new do
      attr_reader :string, :flushes

      def initialize(maximum:, fail_after: nil, error: IOError.new('disk failed'))
        @maximum = maximum
        @fail_after = fail_after
        @error = error
        @writes = 0
        @flushes = 0
        @string = +''
      end

      def write(value)
        raise @error if @fail_after && @writes >= @fail_after

        chunk = value.byteslice(0, @maximum)
        @string << chunk
        @writes += 1
        chunk.bytesize
      end

      def flush
        @flushes += 1
      end
    end
  end
  let(:invalid_write_io_class) do
    Class.new do
      def initialize(result)
        @result = result
      end

      def write(_value)
        @result
      end
    end
  end

  it 'writes one complete compact line and tracks physical bytes' do
    io = StringIO.new
    writer = described_class.new(io: io, max_record_bytes: 16_384)

    bytes = writer.write(record)

    expect(bytes).to eq(io.string.bytesize)
    expect(writer.bytes_written).to eq(bytes)
    expect(io.string.lines.size).to eq(1)
    expect(JSON.parse(io.string)).to eq(record)
  end

  it 'completes short writes without losing or duplicating bytes' do
    io = short_write_io_class.new(maximum: 7)
    writer = described_class.new(io: io, max_record_bytes: 16_384)
    expected = writer.prepare(record)

    expect(writer.write_line(expected)).to eq(expected.bytesize)
    expect(io.string).to eq(expected)
    expect(writer.bytes_written).to eq(expected.bytesize)
    expect(io.flushes).to eq(1)
  end

  it 'poisons the stream after invalid or failed partial writes' do
    [nil, 0, -1].each do |result|
      writer = described_class.new(io: invalid_write_io_class.new(result), max_record_bytes: 16_384)
      expect { writer.write(record) }.to raise_error(FiberAudit::RuntimeSafetyError)
      expect(writer).to be_failed
      expect { writer.write(record) }.to raise_error(FiberAudit::RuntimeSafetyError, /failed/)
      expect { writer.prepare(record) }.to raise_error(FiberAudit::RuntimeSafetyError, /failed/)
    end

    io = short_write_io_class.new(maximum: 10, fail_after: 1)
    writer = described_class.new(io: io, max_record_bytes: 16_384)
    expect { writer.write(record) }.to raise_error(IOError, 'disk failed')
    expect(writer.bytes_written).to eq(10)
    expect(io.string.bytesize).to eq(10)
    expect(writer).to be_failed
  end

  it 'leaves every line before a partially written final record parseable' do
    probe = described_class.new(io: StringIO.new, max_record_bytes: 16_384)
    start_writes = (probe.prepare(record).bytesize / 10.0).ceil
    io = short_write_io_class.new(maximum: 10, fail_after: start_writes + 1)
    writer = described_class.new(io: io, max_record_bytes: 16_384)

    writer.write(record)
    expect { writer.write(event_record) }.to raise_error(IOError, 'disk failed')

    complete_line, partial_line = io.string.split("\n", 2)
    expect(JSON.parse(complete_line)['record_type']).to eq('session_start')
    expect(partial_line).not_to be_empty
    expect { JSON.parse(partial_line) }.to raise_error(JSON::ParserError)
  end

  it 'poisons the stream without swallowing non-StandardError failures' do
    error = Interrupt.new('interrupted')
    io = short_write_io_class.new(maximum: 10, fail_after: 1, error: error)
    writer = described_class.new(io: io, max_record_bytes: 16_384)

    expect { writer.write(record) }.to raise_error(error)
    expect(writer).to be_failed
    expect(writer.bytes_written).to eq(10)
  end

  it 'enforces the record byte boundary before writing' do
    probe = described_class.new(io: StringIO.new, max_record_bytes: 16_384)
    line = probe.prepare(record)
    exact = described_class.new(io: StringIO.new, max_record_bytes: line.bytesize)
    too_small_io = StringIO.new
    too_small = described_class.new(io: too_small_io, max_record_bytes: line.bytesize - 1)

    expect { exact.write(record) }.not_to raise_error
    expect { too_small.write(record) }.to raise_error(FiberAudit::RuntimeSafetyError)
    expect(too_small_io.string).to be_empty
    expect(too_small).to be_active
  end

  it 'does not close injected IO and closes idempotently' do
    io = StringIO.new
    writer = described_class.new(io: io, max_record_bytes: 16_384)
    writer.close
    writer.close

    expect(io).not_to be_closed
    expect(writer).to be_closed
    expect { writer.write(record) }.to raise_error(FiberAudit::RuntimeSafetyError, /closed/)
  end

  it 'creates owned files exclusively with owner-only permissions' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'session.jsonl')
      writer = described_class.open(path: path, max_record_bytes: 16_384)
      writer.write(record)
      writer.close

      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect { described_class.open(path: path, max_record_bytes: 16_384) }
        .to raise_error(Errno::EEXIST)
      expect(JSON.parse(File.read(path))).to eq(record)
    end
  end
end
