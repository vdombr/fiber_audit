# frozen_string_literal: true

require_relative '../errors'

module FiberAudit
  module Runtime
    class Supervisor
      SIGNALS = %w[INT TERM HUP QUIT].select { |name| Signal.list.key?(name) }.freeze

      class SystemAdapter
        def spawn(environment, command, cwd)
          executable = command.fetch(0)
          Process.spawn(
            environment,
            [executable, executable],
            *command.drop(1),
            chdir: cwd,
            pgroup: true
          )
        end

        def wait2(pid)
          Process.wait2(pid)
        end

        def trap(signal, handler = nil, &)
          Signal.trap(signal, handler, &)
        end

        def kill(signal, pid)
          Process.kill(signal, pid)
        end
      end

      def initialize(command:, environment:, cwd:, adapter: SystemAdapter.new)
        validate_command!(command)
        raise RuntimeContractError, 'child environment must be a Hash' unless environment.is_a?(Hash)
        raise RuntimeContractError, 'runtime cwd must be an existing directory' unless File.directory?(cwd)

        @command = command.map { |argument| argument.dup.freeze }.freeze
        @environment = environment.transform_values { |value| value&.dup&.freeze }.freeze
        @cwd = File.expand_path(cwd).freeze
        @adapter = adapter
        @child_pid = nil
      end

      def run
        handlers = {}
        begin
          # Install traps only after spawn so POSIX-spawned children cannot inherit
          # FiberAudit's forwarding handlers and accidentally ignore termination.
          @child_pid = @adapter.spawn(@environment, @command, @cwd)
          install_handlers(handlers)
          _pid, status = wait_for_child
          status_code(status)
        ensure
          restore_handlers(handlers)
          @child_pid = nil
        end
      end

      private

      def validate_command!(command)
        unless command.is_a?(Array) && !command.empty? && command.all?(String)
          raise RuntimeContractError, 'runtime command must be a nonempty Array of Strings'
        end

        command.each_with_index do |argument, index|
          next if argument.valid_encoding? && !argument.include?("\0") && (index.positive? || !argument.empty?)

          raise RuntimeContractError, 'runtime command contains an invalid argument'
        end
      end

      def install_handlers(handlers)
        SIGNALS.each do |signal|
          handlers[signal] = @adapter.trap(signal) { receive_signal(signal) }
        end
      end

      def restore_handlers(handlers)
        handlers.each { |signal, previous| @adapter.trap(signal, previous) }
      end

      def receive_signal(signal)
        forward_signal(signal) if @child_pid
      end

      def forward_signal(signal)
        @adapter.kill(signal, -@child_pid)
      rescue Errno::ESRCH, Errno::EINVAL, NotImplementedError
        begin
          @adapter.kill(signal, @child_pid)
        rescue Errno::ESRCH, Errno::EINVAL, NotImplementedError
          nil
        end
      end

      def wait_for_child
        @adapter.wait2(@child_pid)
      rescue Errno::EINTR
        retry
      end

      def status_code(status)
        return status.exitstatus if status.exited?
        return 128 + status.termsig if status.signaled?

        raise RuntimeSafetyError, 'wrapped command ended without an exit status'
      end
    end
  end
end
