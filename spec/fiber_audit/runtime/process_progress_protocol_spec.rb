# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/runtime/process_progress_protocol'

RSpec.describe FiberAudit::Runtime::ProcessProgressProtocol do
  let(:frame) { described_class.encode(pid: 700, generation: 11, sequence: 3, monotonic_ns: 900) }

  it 'round-trips one fixed-size scalar frame' do
    expect(frame.bytesize).to eq(described_class::FRAME_BYTES)
    expect(described_class.decode(frame)).to have_attributes(pid: 700, generation: 11, sequence: 3, monotonic_ns: 900)
  end

  it 'rejects malformed envelopes and zero fields' do
    malformed = frame.dup
    malformed.setbyte(4, 99)
    expect(described_class.decode(malformed)).to be_nil
    expect(described_class.decode('private-malformed-frame')).to be_nil
    expect { described_class.encode(pid: 0, generation: 1, sequence: 1, monotonic_ns: 1) }
      .to raise_error(FiberAudit::RuntimeContractError, /pid/)
  end

  it 'buffers partial frames and bounds malformed input' do
    decoder = described_class::Decoder.new(max_buffer_bytes: 80)
    expect(decoder.feed(frame.byteslice(0, 13), max_frames: 4).frames).to be_empty
    result = decoder.feed(frame.byteslice(13..), max_frames: 4)
    expect(result.frames).to contain_exactly(described_class::Frame.new(pid: 700, generation: 11, sequence: 3,
                                                                        monotonic_ns: 900))
    malformed = described_class::Decoder.new(max_buffer_bytes: 80).feed('private-sentinel' * 10, max_frames: 1)
    expect(malformed).to be_truncated
    expect(malformed.to_s).not_to include('private-sentinel')
  end
end
