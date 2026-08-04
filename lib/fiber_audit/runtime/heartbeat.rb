# frozen_string_literal: true

require_relative 'clock'

module FiberAudit
  module Runtime
    # Scheduler-owned progress fiber observed by the watchdog thread.
    class Heartbeat
      Snapshot = Data.define(:sequence, :last_progress_ns, :thread_id, :fiber_id, :started, :stop_requested)

      attr_reader :owner_thread

      def initialize(
        interval_ns:,
        clock: Clock.new,
        owner_thread: Thread.current,
        on_tick: ->(_heartbeat) {},
        on_error: ->(_heartbeat, _error) {}
      )
        raise RuntimeContractError, 'clock must be a FiberAudit::Runtime::Clock' unless clock.is_a?(Clock)
        unless interval_ns.is_a?(Integer) && interval_ns.positive?
          raise RuntimeContractError, 'interval_ns must be a positive Integer'
        end
        raise RuntimeContractError, 'owner_thread must be a Thread' unless owner_thread.is_a?(Thread)
        raise RuntimeContractError, 'on_tick must respond to call' unless on_tick.respond_to?(:call)
        raise RuntimeContractError, 'on_error must respond to call' unless on_error.respond_to?(:call)

        @clock = clock
        @interval_ns = interval_ns
        @owner_thread = owner_thread
        @on_tick = on_tick
        @on_error = on_error
        @mutex = Mutex.new
        @sequence = 0
        @last_progress_ns = nil
        @fiber_id = nil
        @started = false
        @start_requested = false
        @stop_requested = false
      end

      def start(schedule: Fiber.method(:schedule), sleeper: Kernel.method(:sleep))
        raise RuntimeContractError, 'schedule must respond to call' unless schedule.respond_to?(:call)
        raise RuntimeContractError, 'sleeper must respond to call' unless sleeper.respond_to?(:call)

        @mutex.synchronize do
          return self if @start_requested

          @start_requested = true
        end
        schedule.call { run(sleeper) }
        self
      rescue StandardError
        @mutex.synchronize { @start_requested = false }
        raise
      end

      def tick
        now_ns = @clock.monotonic_ns
        @mutex.synchronize do
          @sequence += 1
          @last_progress_ns = now_ns
          @fiber_id ||= Fiber.current.object_id
          @started = true
        end
        @on_tick.call(self)
        self
      end

      def request_stop
        @mutex.synchronize { @stop_requested = true }
        self
      end

      def snapshot
        @mutex.synchronize do
          Snapshot.new(
            sequence: @sequence,
            last_progress_ns: @last_progress_ns,
            thread_id: owner_thread.object_id,
            fiber_id: @fiber_id,
            started: @started,
            stop_requested: @stop_requested
          )
        end
      end

      def started?
        @mutex.synchronize { @started }
      end

      def stop_requested?
        @mutex.synchronize { @stop_requested }
      end

      private

      def run(sleeper)
        tick
        loop do
          break if stop_requested?

          sleeper.call(@interval_ns.fdiv(1_000_000_000))
          break if stop_requested?

          tick
        end
      rescue StandardError => e
        @on_error.call(self, e)
      end
    end
  end
end
