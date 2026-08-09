# frozen_string_literal: true

require_relative '../../../support/runtime_probe_harness'

RSpec.describe FiberAudit::Runtime::Probes::IOSelect do
  after { stop_probe_runtime(@runtime) if @runtime }

  it 'preserves IO.select results and records timeout presence only' do
    @runtime = start_probe_runtime
    reader, writer = IO.pipe
    writer.write('x')

    # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler -- this is the API under test.
    result = IO.select([reader], nil, nil, 0.1)
    # rubocop:enable Lint/IncompatibleIoSelectWithFiberScheduler

    expect(result.first).to eq([reader])
    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'IO.select' }
    expect(event.dig('payload', 'measurements', 'timeout_present')).to be(true)
  ensure
    reader&.close
    writer&.close
  end

  it 'distinguishes a nil Kernel.select timeout without recording values' do
    @runtime = start_probe_runtime
    reader, writer = IO.pipe
    writer.write('x')

    expect(select([reader], [], [], nil).first).to eq([reader])
    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'Kernel.select' }

    expect(event.dig('payload', 'measurements', 'timeout_present')).to be(false)
    expect(@runtime.io.string).not_to include('0.123456789')
  ensure
    reader&.close
    writer&.close
  end

  it 're-raises invalid argument errors unchanged' do
    @runtime = start_probe_runtime
    error = nil

    begin
      IO.select(Object.new)
    rescue TypeError => e
      error = e
    end

    expect(error).to be_a(TypeError)
    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'IO.select' }
    expect(event.dig('payload', 'kind')).to eq('operation_aborted')
    expect(@runtime.io.string).not_to include(error.message)
  end
end
