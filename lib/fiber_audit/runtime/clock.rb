# frozen_string_literal: true

require_relative 'validation'

module FiberAudit
  module Runtime
    class Clock
      MAX_NANOSECONDS = 9_223_372_036_854_775_807
      WALL_SOURCE = -> { Time.now }.freeze
      MONOTONIC_SOURCE = lambda {
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      }.freeze

      def initialize(wall: WALL_SOURCE, monotonic: MONOTONIC_SOURCE)
        raise RuntimeContractError, 'wall clock source must respond to call' unless wall.respond_to?(:call)
        raise RuntimeContractError, 'monotonic clock source must respond to call' unless monotonic.respond_to?(:call)

        @wall = wall
        @monotonic = monotonic
        freeze
      end

      def wall_time
        Validation.utc_time(@wall.call, 'wall clock result')
      end

      def monotonic_ns
        value = Validation.integer(@monotonic.call, 'monotonic clock result')
        raise RuntimeSafetyError, 'monotonic clock result exceeds signed 64-bit range' if value > MAX_NANOSECONDS

        value
      end
    end
  end
end
