# frozen_string_literal: true

require_relative '../execution_context'

module FiberAudit
  module Runtime
    # Fiber-local execution context stack.
    # Uses fiber instance variables for isolation without Thread#[] visibility.
    # PID-aware to handle fork correctly.
    module ExecutionContext
      MAX_DEPTH = 32
      IVAR_KEY = :@__fiber_audit_execution_context__
      IVAR_PID_KEY = :@__fiber_audit_execution_context_pid__

      class << self
        def current
          state = current_state
          return Context::UNKNOWN unless state

          state[:stack].last || Context::UNKNOWN
        end

        def with(context)
          normalized = validate_context(context)
          state = ensure_state
          return yield if state[:stack].size >= MAX_DEPTH

          state[:stack].push(normalized)
          begin
            yield
          ensure
            state[:stack].pop
          end
        end

        def reset!
          fiber = Fiber.current
          fiber.remove_instance_variable(IVAR_KEY) if fiber.instance_variable_defined?(IVAR_KEY)
          fiber.remove_instance_variable(IVAR_PID_KEY) if fiber.instance_variable_defined?(IVAR_PID_KEY)
        end

        def after_fork!
          reset!
        end

        private

        def current_state
          fiber = Fiber.current
          return nil unless fiber.instance_variable_defined?(IVAR_KEY)

          pid = fiber.instance_variable_defined?(IVAR_PID_KEY) ? fiber.instance_variable_get(IVAR_PID_KEY) : nil
          return nil unless pid == Process.pid

          { stack: fiber.instance_variable_get(IVAR_KEY), pid: pid }
        end

        def ensure_state
          fiber = Fiber.current
          pid = Process.pid

          if fiber.instance_variable_defined?(IVAR_KEY)
            stored_pid = fiber.instance_variable_defined?(IVAR_PID_KEY) ? fiber.instance_variable_get(IVAR_PID_KEY) : nil
            return { stack: fiber.instance_variable_get(IVAR_KEY), pid: pid } if stored_pid == pid

            # PID mismatch - reset
            reset!
          end

          stack = []
          fiber.instance_variable_set(IVAR_KEY, stack)
          fiber.instance_variable_set(IVAR_PID_KEY, pid)
          { stack: stack, pid: pid }
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
