# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require_relative '../../../support/runtime_probe_harness'

RSpec.describe FiberAudit::Runtime::Probes::Subprocess do
  after { stop_probe_runtime(@runtime) if @runtime }

  it 'preserves subprocess return values, blocks, and canonical operations' do
    @runtime = start_probe_runtime
    sentinel = Object.new

    expect(Kernel.system(RbConfig.ruby, '-e', 'exit 0')).to be(true)
    returned = IO.popen([RbConfig.ruby, '-e', 'puts :ok']) do |stream|
      expect(stream.read).to eq("ok\n")
      sentinel
    end
    stdout, status = Open3.capture2(RbConfig.ruby, '-e', 'puts :captured')

    expect(returned).to equal(sentinel)
    expect(stdout).to eq("captured\n")
    expect(status).to be_success
    expect(operations(@runtime)).to include('Kernel.system', 'IO.popen', 'Open3.capture2')
  end

  it 'covers the remaining exact Kernel, Process, and Open3 targets' do
    @runtime = start_probe_runtime

    spawned = Kernel.spawn(RbConfig.ruby, '-e', 'exit 0')
    Process.wait(spawned)
    detached_pid = Process.spawn(RbConfig.ruby, '-e', 'exit 0')
    Process.detach(detached_pid).value
    2.times { Process.spawn(RbConfig.ruby, '-e', 'exit 0') }
    Process.waitall
    Open3.capture2e(RbConfig.ruby, '-e', 'puts :capture2e')
    Open3.capture3(RbConfig.ruby, '-e', 'puts :capture3')
    Open3.pipeline([RbConfig.ruby, '-e', 'exit 0'])

    expect(operations(@runtime)).to include(
      'Kernel.spawn', 'Process.detach', 'Process.waitall',
      'Open3.capture2e', 'Open3.capture3', 'Open3.pipeline'
    )
  end

  it 're-raises the same block exception and emits aborted evidence' do
    @runtime = start_probe_runtime
    error = Class.new(StandardError).new('subprocess-secret-error')

    expect do
      IO.popen([RbConfig.ruby, '-e', 'exit 0']) { raise error }
    end.to(raise_error { |raised| expect(raised).to equal(error) })

    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'IO.popen' }
    expect(event.dig('payload', 'kind')).to eq('operation_aborted')
    expect(@runtime.io.string).not_to include('subprocess-secret-error')
  end

  it 'emits a start and aborted pair for an exec that cannot replace the process' do
    @runtime = start_probe_runtime
    missing = File.join(Dir.pwd, 'missing-secret-executable')

    expect { Kernel.exec(missing) }.to raise_error(Errno::ENOENT)

    exec_events = probe_events(@runtime).select { |record| record.dig('payload', 'operation') == 'Kernel.exec' }
    expect(exec_events.map { |record| record.dig('payload', 'kind') })
      .to eq(%w[operation_started operation_aborted])
    expect(@runtime.io.string).not_to include('missing-secret-executable')
  end

  it 'does not serialize commands, output, or exception messages' do
    @runtime = start_probe_runtime
    secret = 'command-token-stage5-secret'

    Open3.capture3(RbConfig.ruby, '-e', "warn #{secret.inspect}")

    expect(@runtime.io.string).not_to include(secret)
  end
end
