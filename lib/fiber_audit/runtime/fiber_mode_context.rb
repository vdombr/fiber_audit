# frozen_string_literal: true

module FiberAudit
  module Runtime
    # Process-, Thread-, and Fiber-local provenance for explicit blocking regions.
    module FiberModeContext
      MAX_DEPTH = 32
      FRAME_KEY = :__fiber_audit_fiber_mode_context_frame__
      KINDS = %i[fiber_new fiber_blocking].freeze

      ABSENT_MEASUREMENTS = {
        fiber_blocking_context_present: false,
        fiber_blocking_context_depth: 0,
        fiber_blocking_context_fiber_new: false,
        fiber_blocking_context_fiber_blocking: false,
        fiber_blocking_context_truncated: false
      }.freeze
      UNKNOWN_MEASUREMENTS = ABSENT_MEASUREMENTS.transform_values { nil }.freeze

      Frame = Data.define(:kind, :depth, :truncated, :pid, :thread_id, :fiber_id, :generation)
      private_constant :Frame

      @generation_token = Object.new.freeze

      class << self
        def current
          current_frame&.kind
        end

        def measurements
          frame = current_frame
          return ABSENT_MEASUREMENTS unless frame

          {
            fiber_blocking_context_present: true,
            fiber_blocking_context_depth: frame.depth,
            fiber_blocking_context_fiber_new: frame.kind == :fiber_new,
            fiber_blocking_context_fiber_blocking: frame.kind == :fiber_blocking,
            fiber_blocking_context_truncated: frame.truncated
          }.freeze
        rescue StandardError
          UNKNOWN_MEASUREMENTS
        end

        def with(kind)
          normalized_kind = normalize_kind(kind)
          parent = current_frame
          requested_depth = parent ? parent.depth + 1 : 1
          frame = Frame.new(
            kind: normalized_kind,
            depth: [requested_depth, MAX_DEPTH].min,
            truncated: parent&.truncated || requested_depth > MAX_DEPTH,
            pid: Process.pid,
            thread_id: Thread.current.object_id,
            fiber_id: Fiber.current.object_id,
            generation: generation_token
          )
          Fiber[FRAME_KEY] = frame
          yield
        ensure
          restore_frame(frame, parent) if defined?(frame) && frame
        end

        def clear!
          Fiber[FRAME_KEY] = nil
          nil
        rescue StandardError
          nil
        end

        def reset!
          @generation_token = Object.new.freeze
          clear!
        end

        def after_fork!
          reset!
        end

        private

        def current_frame
          valid_frame(Fiber[FRAME_KEY])
        rescue StandardError
          nil
        end

        def valid_frame(frame)
          return unless frame.is_a?(Frame)
          return unless frame.pid == Process.pid
          return unless frame.thread_id == Thread.current.object_id
          return unless frame.fiber_id == Fiber.current.object_id
          return unless frame.generation.equal?(generation_token)

          frame
        end

        def normalize_kind(value)
          normalized = value.to_sym if value.respond_to?(:to_sym)
          return normalized if KINDS.include?(normalized)

          raise RuntimeContractError, "unknown Fiber mode context: #{value.inspect}"
        end

        def generation_token
          @generation_token ||= Object.new.freeze
        end

        def restore_frame(frame, parent)
          return unless Fiber[FRAME_KEY].equal?(frame)

          Fiber[FRAME_KEY] = frame.generation.equal?(generation_token) ? parent : nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
