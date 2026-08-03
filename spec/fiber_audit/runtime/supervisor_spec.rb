# frozen_string_literal: true

require 'rbconfig'
require 'tmpdir'
require 'fiber_audit/runtime/supervisor'

RSpec.describe FiberAudit::Runtime::Supervisor do
  let(:status_class) do
    Struct.new(:exitstatus, :termsig, :mode) do
      def exited?
        mode == :exited
      end

      def signaled?
        mode == :signaled
      end
    end
  end

  let(:adapter_class) do
    Class.new do
      attr_reader :spawn_arguments, :signals, :restored

      def initialize(status:, interrupts: 0, signal_during_wait: nil, spawn_error: nil)
        @status = status
        @interrupts = interrupts
        @signal_during_wait = signal_during_wait
        @spawn_error = spawn_error
        @handlers = {}
        @signals = []
        @restored = {}
      end

      def spawn(environment, command, cwd)
        @spawn_arguments = [environment, command, cwd]
        raise @spawn_error if @spawn_error

        4321
      end

      def wait2(pid)
        raise Errno::EINTR if (@interrupts -= 1) >= 0

        if @signal_during_wait
          @handlers.fetch(@signal_during_wait).call
          @signal_during_wait = nil
        end
        [pid, @status]
      end

      def trap(signal, handler = nil, &block)
        if block
          @handlers[signal] = block
          "previous-#{signal}"
        else
          @restored[signal] = handler
        end
      end

      def kill(signal, pid)
        @signals << [signal, pid]
      end
    end
  end

  def build_supervisor(adapter, command: ['ruby', 'argument with spaces'])
    described_class.new(
      command: command,
      environment: { 'SAFE' => '1' },
      cwd: Dir.pwd,
      adapter: adapter
    )
  end

  it 'preserves command boundaries and returns a normal child status' do
    status = status_class.new(7, nil, :exited)
    adapter = adapter_class.new(status: status)

    expect(build_supervisor(adapter, command: ['tool', 'a; echo no', '*.rb']).run).to eq(7)
    expect(adapter.spawn_arguments).to eq(
      [{ 'SAFE' => '1' }, ['tool', 'a; echo no', '*.rb'], Dir.pwd]
    )
    described_class::SIGNALS.each do |signal|
      expect(adapter.restored.fetch(signal)).to eq("previous-#{signal}")
    end
  end

  it 'converts signal termination to the conventional shell status' do
    signal = Signal.list.fetch('TERM')
    status = status_class.new(nil, signal, :signaled)
    adapter = adapter_class.new(status: status)

    expect(build_supervisor(adapter).run).to eq(128 + signal)
  end

  it 'forwards signals to the child process group' do
    signal = described_class::SIGNALS.first
    status = status_class.new(0, nil, :exited)
    adapter = adapter_class.new(status: status, signal_during_wait: signal)

    expect(build_supervisor(adapter).run).to eq(0)
    expect(adapter.signals).to include([signal, -4321])
  end

  it 'retries interrupted waits' do
    status = status_class.new(0, nil, :exited)
    adapter = adapter_class.new(status: status, interrupts: 2)

    expect(build_supervisor(adapter).run).to eq(0)
  end

  it 'does not alter signal handlers when spawn fails' do
    status = status_class.new(0, nil, :exited)
    error = Errno::ENOENT.new('missing')
    adapter = adapter_class.new(status: status, spawn_error: error)

    expect { build_supervisor(adapter).run }.to raise_error(error)
    expect(adapter.restored).to be_empty
  end

  it 'creates a child process group without shell interpolation' do
    adapter = described_class::SystemAdapter.new
    command = ['tool', 'argument with spaces']
    expect(Process).to receive(:spawn).with(
      { 'SAFE' => '1' },
      %w[tool tool],
      'argument with spaces',
      chdir: Dir.pwd,
      pgroup: true
    ).and_return(4321)

    expect(adapter.spawn({ 'SAFE' => '1' }, command, Dir.pwd)).to eq(4321)
  end

  it 'rejects invalid commands without including argument contents' do
    status = status_class.new(0, nil, :exited)
    adapter = adapter_class.new(status: status)

    [[], [nil], ['', 'argument'], ["bad\0command"]].each do |command|
      expect { build_supervisor(adapter, command: command) }
        .to raise_error(FiberAudit::RuntimeContractError, /runtime command/)
    end
  end

  it 'executes command arguments without shell interpolation' do
    Dir.mktmpdir do |directory|
      marker = File.join(directory, 'marker')
      script = 'exit(ARGV == ["not shell; touch marker", "*.rb"] ? 0 : 1)'
      command = [RbConfig.ruby, '-e', script, 'not shell; touch marker', '*.rb']
      supervisor = described_class.new(command: command, environment: {}, cwd: directory)

      expect(supervisor.run).to eq(0)
      expect(File).not_to exist(marker)
    end
  end
end
