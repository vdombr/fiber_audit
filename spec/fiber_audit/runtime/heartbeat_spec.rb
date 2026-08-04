# frozen_string_literal: true

require 'fiber_audit/runtime/heartbeat'

RSpec.describe FiberAudit::Runtime::Heartbeat do
  def clock(values)
    times = values.dup
    FiberAudit::Runtime::Clock.new(
      wall: -> { Time.utc(2026, 8, 2, 12) },
      monotonic: -> { times.shift || values.last }
    )
  end

  it 'ticks only when its scheduled fiber executes' do
    block = nil
    ticks = []
    heartbeat = described_class.new(
      clock: clock([10]),
      interval_ns: 25_000_000,
      on_tick: ->(value) { ticks << value.snapshot.sequence }
    )

    heartbeat.start(schedule: ->(&scheduled) { block = scheduled })
    expect(heartbeat.snapshot).to have_attributes(started: false, sequence: 0)

    heartbeat.request_stop
    block.call
    expect(heartbeat.snapshot).to have_attributes(started: true, sequence: 1, stop_requested: true)
    expect(ticks).to eq([1])
  end

  it 'uses scheduler-friendly waits and updates progress after each wake' do
    waits = []
    heartbeat = nil
    sleeper = lambda do |seconds|
      waits << seconds
      heartbeat.request_stop if waits.size == 2
    end
    heartbeat = described_class.new(clock: clock([10, 20]), interval_ns: 25_000_000)

    heartbeat.start(schedule: ->(&block) { block.call }, sleeper: sleeper)

    expect(waits).to eq([0.025, 0.025])
    expect(heartbeat.snapshot).to have_attributes(sequence: 2, last_progress_ns: 20)
  end

  it 'is start-idempotent and stop-idempotent' do
    scheduled = 0
    heartbeat = described_class.new(clock: clock([10]), interval_ns: 1)
    scheduler = lambda do |&_block|
      scheduled += 1
    end

    2.times { heartbeat.start(schedule: scheduler) }
    2.times { heartbeat.request_stop }

    expect(scheduled).to eq(1)
    expect(heartbeat).to be_stop_requested
  end

  it 'reports StandardError failures without swallowing non-StandardError failures' do
    error = IOError.new('clock unavailable')
    reported = []
    heartbeat = described_class.new(
      clock: FiberAudit::Runtime::Clock.new(
        wall: -> { Time.now },
        monotonic: -> { raise error }
      ),
      interval_ns: 1,
      on_error: ->(_value, failure) { reported << failure }
    )

    heartbeat.start(schedule: ->(&block) { block.call })
    expect(reported).to eq([error])

    interrupt = Interrupt.new('stop')
    fatal = described_class.new(clock: clock([1]), interval_ns: 1)
    expect do
      fatal.start(schedule: ->(&_block) { raise interrupt })
    end.to raise_error(interrupt)
  end

  it 'validates construction and scheduling dependencies' do
    expect { described_class.new(clock: Object.new, interval_ns: 1) }
      .to raise_error(FiberAudit::RuntimeContractError, /clock/)
    heartbeat = described_class.new(clock: clock([1]), interval_ns: 1)
    expect { heartbeat.start(schedule: Object.new) }
      .to raise_error(FiberAudit::RuntimeContractError, /schedule/)
  end
end
