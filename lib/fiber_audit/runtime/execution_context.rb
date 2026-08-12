# frozen_string_literal: true

require_relative '../execution_context'

module FiberAudit
  module Runtime
    # Fiber-local execution context with propagation to child fibers.
    # Uses Ruby Fiber storage (Fiber[]) for fiber-local state that is
    # inherited by child fibers at creation, enabling automatic context
    # propagation across Fiber boundaries.
    #
    # Frames are immutable (frozen Data objects) forming a linked list.
    # Each +with+ call creates a new frame pointing to the parent frame.
    #
    # Semantics:
    # - Child fibers inherit the parent fiber's current context at creation
    # - Child fiber overrides do not alter parent context
    # - +clear!+ removes context for the current fiber only
    # - +clear!+ inside nested +with+ is not undone by the enclosing ensure
    #   (ensure restores only when its own frame is still the active one)
    # - Thread isolation is maintained (each thread has its own Fiber storage)
    # - PID mismatch (after fork) is treated as empty context
    # - MAX_DEPTH overflow exposes :unknown rather than stale outer context
    module ExecutionContext
      MAX_DEPTH = 32
      FRAME_KEY = :__fiber_audit_execution_context_frame__
      PID_KEY   = :__fiber_audit_execution_context_pid__

      # Immutable frame in the context chain.
      Frame = Data.define(:context, :parent, :depth)
      private_constant :Frame

      class << self
        def current
          frame = current_frame
          frame ? frame.context : Context::UNKNOWN
        end

        # rubocop:disable Metrics/MethodLength
        def with(context)
          normalized = validate_context(context)
          parent = current_frame

          new_depth = parent ? parent.depth + 1 : 1
          effective = new_depth > MAX_DEPTH ? Context::UNKNOWN : normalized
          frame = Frame.new(context: effective, parent: parent, depth: new_depth)

          Fiber[FRAME_KEY] = frame
          Fiber[PID_KEY] = Process.pid
          begin
            yield
          ensure
            # Only restore if our frame is still the active one.
            # If clear! was called (or another with replaced it), skip restore.
            Fiber[FRAME_KEY] = parent if Fiber[FRAME_KEY].equal?(frame)
          end
        end
        # rubocop:enable Metrics/MethodLength

        def clear!
          Fiber[FRAME_KEY] = nil
          Fiber[PID_KEY] = nil
        end

        # Compatibility alias for clear!.
        def reset!
          clear!
        end

        # Clear context after fork.
        def after_fork!
          clear!
        end

        private

        def current_frame
          return nil unless Fiber[PID_KEY] == Process.pid

          Fiber[FRAME_KEY]
        end

        def validate_context(value)
          unless value.is_a?(Symbol) || value.is_a?(String)
            raise RuntimeContractError, 'execution_context must be a Symbol or String'
          end

          normalized = value.is_a?(Symbol) ? value : value.to_sym
          return normalized if Context::ALL.include?(normalized)

          raise RuntimeContractError, 'execution_context is invalid'
        end
      end
    end
  end
end
