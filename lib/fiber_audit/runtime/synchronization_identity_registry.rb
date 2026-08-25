# frozen_string_literal: true

require 'objspace'

module FiberAudit
  module Runtime
    class SynchronizationIdentityRegistry
      attr_reader :capacity

      def initialize(capacity:, pid_source: Process.method(:pid))
        unless capacity.is_a?(Integer) && capacity.positive?
          raise RuntimeContractError,
                'capacity must be a positive Integer'
        end
        raise RuntimeContractError, 'pid_source must respond to call' unless pid_source.respond_to?(:call)

        @capacity = capacity
        @pid_source = pid_source
        reset_for_process!(current_pid)
      end

      def id_for(object)
        raise RuntimeContractError, 'identity object must not be nil' if object.nil?

        ensure_current_process!
        @mutex.synchronize do
          existing = @identities[object]
          return existing if existing

          if @identities.size >= capacity
            @truncated = true
            return nil
          end
          @sequence += 1
          @identities[object] = @sequence
          @sequence
        end
      rescue TypeError
        raise RuntimeContractError, 'identity object must support weak identity'
      end

      def size
        ensure_current_process!
        @mutex.synchronize { @identities.size }
      end

      def truncated?
        ensure_current_process!
        @mutex.synchronize { @truncated }
      end

      def clear!
        reset_for_process!(current_pid)
        self
      end

      def after_fork! = clear!

      private

      def ensure_current_process!
        pid = current_pid
        reset_for_process!(pid) unless pid == @owner_pid
      end

      def reset_for_process!(pid)
        @owner_pid = pid
        @mutex = Mutex.new
        @identities = ObjectSpace::WeakMap.new
        @sequence = 0
        @truncated = false
      end

      def current_pid
        value = @pid_source.call
        return value if value.is_a?(Integer) && value.positive?

        raise RuntimeContractError, 'pid source must return a positive Integer'
      end
    end
  end
end
