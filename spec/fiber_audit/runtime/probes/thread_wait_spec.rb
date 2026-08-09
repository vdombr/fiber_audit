# frozen_string_literal: true

require_relative '../../../support/runtime_probe_harness'

RSpec.describe FiberAudit::Runtime::Probes::ThreadWait do
  after { stop_probe_runtime(@runtime) if @runtime }

  it 'preserves join timeout behavior and thread value identity' do
    @runtime = start_probe_runtime
    release = Queue.new
    value = Object.new
    thread = Thread.new do
      release.pop
      value
    end

    expect(thread.join(0)).to be_nil
    release << true
    expect(thread.value).to equal(value)

    expect(operations(@runtime)).to include('Thread.join', 'Thread.value')
  end

  it 're-raises the exact thread exception without recording it' do
    @runtime = start_probe_runtime
    error = Class.new(StandardError).new('thread-value-stage5-secret')
    thread = Thread.new { raise error }
    thread.report_on_exception = false

    expect { thread.value }.to(raise_error { |raised| expect(raised).to equal(error) })

    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'Thread.value' }
    expect(event.dig('payload', 'kind')).to eq('operation_aborted')
    expect(@runtime.io.string).not_to include('thread-value-stage5-secret')
  end
end
