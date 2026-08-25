# frozen_string_literal: true

require_relative '../errors'
require_relative 'environment'
require_relative 'process_progress_monitor'
require_relative 'process_progress_policy'

module FiberAudit
  module Runtime
    class Supervisor
      SIGNALS = %w[INT TERM HUP QUIT].select { |name| Signal.list.key?(name) }.freeze

      class SystemAdapter
        def spawn(environment, command, cwd, inherited_io: nil)
          executable = command.fetch(0)
          arguments = [environment, [executable, executable], *command.drop(1)]
          options = { chdir: cwd, pgroup: true }
          options[inherited_io.fileno] = inherited_io.fileno if inherited_io
          Process.spawn(*arguments, **options)
        end

        def wait2(pid) = Process.wait2(pid)
        def trap(signal, handler = nil, &) = Signal.trap(signal, handler, &)
        def kill(signal, pid) = Process.kill(signal, pid)
      end

      def initialize(command:, environment:, cwd:, settings: nil,
                     process_progress_policy: ProcessProgressPolicy::DISABLED,
                     adapter: SystemAdapter.new, pipe_factory: IO.method(:pipe),
                     monitor_factory: ProcessProgressMonitor.method(:start))
        validate_command!(command)
        raise RuntimeContractError, 'child environment must be a Hash' unless environment.is_a?(Hash)
        raise RuntimeContractError, 'runtime cwd must be an existing directory' unless File.directory?(cwd)
        unless process_progress_policy.is_a?(ProcessProgressPolicy)
          raise RuntimeContractError,
                'process_progress_policy must be a ProcessProgressPolicy'
        end
        if process_progress_policy.enabled? && !settings.is_a?(Environment::Settings)
          raise RuntimeContractError, 'enabled process progress requires runtime settings'
        end
        raise RuntimeContractError, 'pipe_factory must respond to call' unless pipe_factory.respond_to?(:call)
        raise RuntimeContractError, 'monitor_factory must respond to call' unless monitor_factory.respond_to?(:call)

        @command = command.map { |argument| argument.dup.freeze }.freeze
        @environment = environment.transform_values { |value| value&.dup&.freeze }.freeze
        @cwd = File.expand_path(cwd).freeze
        @settings = settings
        @process_progress_policy = process_progress_policy
        @adapter = adapter
        @pipe_factory = pipe_factory
        @monitor_factory = monitor_factory
        @child_pid = nil
      end

      def run
        handlers = {}
        progress_reader = progress_writer = monitor = nil
        begin
          child_environment = @environment
          if @process_progress_policy.enabled?
            progress_reader, progress_writer = build_progress_pipe
            child_environment = Environment.attach_process_progress_transport(
              child_environment, policy: @process_progress_policy, writer_fd: progress_writer.fileno
            )
          end
          @child_pid = if progress_writer
                         @adapter.spawn(child_environment, @command, @cwd, inherited_io: progress_writer)
                       else
                         @adapter.spawn(child_environment, @command, @cwd)
                       end
          close_io(progress_writer)
          progress_writer = nil
          monitor, progress_reader = activate_parent_monitor(progress_reader) if progress_reader
          install_handlers(handlers)
          _pid, status = wait_for_child
          status_code(status)
        ensure
          restore_handlers(handlers)
          monitor&.stop
          close_io(progress_reader)
          close_io(progress_writer)
          @child_pid = nil
        end
      end

      private

      def activate_parent_monitor(progress_reader)
        monitor = @monitor_factory.call(policy: @process_progress_policy, settings: @settings,
                                        reader: progress_reader)
        return [nil, nil] unless monitor

        [monitor, nil]
      rescue StandardError => e
        close_io(progress_reader)
        return [nil, nil] if @settings&.policy&.fail_open?

        begin
          forward_signal('KILL')
          wait_for_child
        rescue Errno::ECHILD
          nil
        ensure
          @child_pid = nil
        end
        raise e
      end

      def build_progress_pipe
        pair = @pipe_factory.call
        unless pair.is_a?(Array) && pair.size == 2 && pair.all? { |io| io.respond_to?(:close) && io.respond_to?(:fileno) }
          raise RuntimeContractError, 'pipe_factory must return a reader and writer IO pair'
        end

        reader, writer = pair
        reader.binmode if reader.respond_to?(:binmode)
        writer.binmode if writer.respond_to?(:binmode)
        reader.close_on_exec = true if reader.respond_to?(:close_on_exec=)
        writer.close_on_exec = false if writer.respond_to?(:close_on_exec=)
        [reader, writer]
      rescue StandardError
        close_io(reader) if defined?(reader)
        close_io(writer) if defined?(writer)
        raise
      end

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
        SIGNALS.each { |signal| handlers[signal] = @adapter.trap(signal) { receive_signal(signal) } }
      end

      def restore_handlers(handlers) = handlers.each { |signal, previous| @adapter.trap(signal, previous) }

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

      def close_io(io)
        io&.close unless io&.closed?
      end
    end
  end
end
