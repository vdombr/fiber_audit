# frozen_string_literal: true

require 'securerandom'
require_relative 'clock'
require_relative 'event'
require_relative 'process_progress_policy'
require_relative 'process_progress_protocol'
require_relative 'recorder'

module FiberAudit
  module Runtime
    class ProcessProgressEmitter
      SOURCE = :process_progress_emitter
      STOP_TIMEOUT_SECONDS = 1
      STATES = %i[active disabled unsupported stopped].freeze
      attr_reader :policy, :recorder, :state, :owner_pid, :generation

      def initialize(
        policy:, recorder:, writer: nil, clock: Clock.new, pid_source: Process.method(:pid),
        generation_source: lambda {
          SecureRandom.random_number(ProcessProgressProtocol::MAX_UINT64) + 1
        },
        thread_factory: lambda { |&block|
          Thread.new(&block)
        }
      )
        validate_dependencies!(policy, recorder, writer, clock, pid_source, generation_source, thread_factory)
        @policy = policy
        @recorder = recorder
        @writer = writer
        @clock = clock
        @pid_source = pid_source
        @generation_source = generation_source
        @thread_factory = thread_factory
        @owner_pid = current_pid
        @generation = generation_id
        @sequence = 0
        @frames_written = @frames_dropped = @internal_errors = 0
        @write_mutex = Mutex.new
        @wait_mutex = Mutex.new
        @condition = ConditionVariable.new
        @stopping = false
        @thread = nil
        activate!
      rescue StandardError => e
        activation_failure!(e)
      end

      def active? = state == :active
      def enabled? = policy.enabled?

      def emit_progress
        return :inactive unless active?

        @write_mutex.synchronize do
          @sequence += 1
          frame = ProcessProgressProtocol.encode(pid: owner_pid, generation: generation, sequence: @sequence,
                                                 monotonic_ns: @clock.monotonic_ns)
          result = @writer.write_nonblock(frame, exception: false)
          if result == frame.bytesize
            @frames_written += 1
            :written
          else
            @frames_dropped += 1
            :dropped
          end
        end
      rescue IO::WaitWritable, Errno::EAGAIN, Errno::EWOULDBLOCK
        @frames_dropped += 1
        :dropped
      rescue StandardError => e
        handle_failure(e)
        :unsupported
      end

      def stop
        return self if state == :stopped

        @wait_mutex.synchronize do
          @stopping = true
          @condition.broadcast
        end
        stop_thread
        emit_state(:process_progress_completed, measurements: counter_measurements)
        close_writer
        @state = :stopped
        self
      rescue StandardError => e
        account_internal_error(e)
        close_writer
        @state = :stopped
        raise e unless fail_open?

        self
      end

      private

      def validate_dependencies!(candidate_policy, candidate_recorder, writer, clock, pids, generations, threads)
        unless candidate_policy.is_a?(ProcessProgressPolicy)
          raise RuntimeContractError,
                'policy must be a FiberAudit::Runtime::ProcessProgressPolicy'
        end
        unless candidate_recorder.is_a?(Recorder)
          raise RuntimeContractError,
                'recorder must be a FiberAudit::Runtime::Recorder'
        end
        unless writer.nil? || writer.respond_to?(:write_nonblock)
          raise RuntimeContractError,
                'writer must respond to write_nonblock or be nil'
        end
        raise RuntimeContractError, 'clock must be a FiberAudit::Runtime::Clock' unless clock.is_a?(Clock)
        raise RuntimeContractError, 'pid_source must respond to call' unless pids.respond_to?(:call)
        raise RuntimeContractError, 'generation_source must respond to call' unless generations.respond_to?(:call)
        raise RuntimeContractError, 'thread_factory must respond to call' unless threads.respond_to?(:call)
        raise RuntimeContractError, 'enabled process progress requires a writer' if candidate_policy.enabled? && writer.nil?
        return unless writer && !candidate_policy.enabled?

        raise RuntimeContractError,
              'writer requires an enabled process progress policy'
      end

      def activate!
        if !policy.enabled?
          @state = :disabled
          emit_state(:process_progress_disabled)
        elsif @writer.nil?
          @state = :unsupported
          emit_state(:process_progress_unsupported)
        else
          @state = :active
          emit_progress
          start_thread
          emit_state(:process_progress_active)
        end
      end

      def start_thread
        @thread = @thread_factory.call { run }
        raise RuntimeContractError, 'thread_factory must return a Thread' unless @thread.is_a?(Thread)

        @thread.report_on_exception = false
        @thread.abort_on_exception = !fail_open?
        @thread.name = 'fiber-audit-process-progress' if @thread.respond_to?(:name=)
      end

      def run
        loop do
          stop = @wait_mutex.synchronize do
            @condition.wait(@wait_mutex, policy.heartbeat_interval_ms.fdiv(1_000)) unless @stopping
            @stopping
          end
          break if stop

          emit_progress
        end
      rescue StandardError => e
        handle_failure(e)
        raise e unless fail_open?
      end

      def stop_thread
        thread = @thread
        return unless thread && thread != Thread.current
        return if thread.join(STOP_TIMEOUT_SECONDS)

        account_internal_error(RuntimeSafetyError.new('process progress emitter thread did not stop'))
        thread.kill
        thread.join
      ensure
        @thread = nil
      end

      def activation_failure!(error)
        @state = :unsupported
        account_internal_error(error) if defined?(@recorder) && @recorder
        emit_state(:process_progress_unsupported) if defined?(@recorder) && @recorder
        raise error unless !defined?(@recorder) || !@recorder || fail_open?
      end

      def handle_failure(error)
        return if state == :unsupported

        @state = :unsupported
        account_internal_error(error)
        @wait_mutex.synchronize do
          @stopping = true
          @condition.broadcast
        end
        emit_state(:process_progress_unsupported, measurements: counter_measurements)
        raise error unless fail_open?
      rescue StandardError
        raise error unless fail_open?
      end

      def emit_state(kind, measurements: policy_measurements)
        recorder.record_control do
          Event.new(kind: kind, source: SOURCE, occurred_at: @clock.wall_time, monotonic_ns: @clock.monotonic_ns,
                    measurements: measurements)
        end
      end

      def policy_measurements
        {
          heartbeat_interval_ns: policy.heartbeat_interval_ns,
          stall_threshold_ns: policy.stall_threshold_ns,
          max_processes: policy.max_processes, max_frames_per_poll: policy.max_frames_per_poll,
          max_buffer_bytes: policy.max_buffer_bytes
        }
      end

      def counter_measurements
        policy_measurements.merge(frames_written: @frames_written, frames_dropped: @frames_dropped,
                                  emitter_internal_errors: @internal_errors)
      end

      def account_internal_error(_error)
        @internal_errors += 1
        recorder.internal_error!
      rescue StandardError
        nil
      end

      def close_writer
        @writer&.close unless @writer&.closed?
      rescue StandardError => e
        account_internal_error(e)
        raise e unless fail_open?
      ensure
        @writer = nil
      end

      def fail_open? = recorder.session.policy.fail_open?

      def current_pid
        value = @pid_source.call
        unless value.is_a?(Integer) && value.positive?
          raise RuntimeContractError,
                'pid source must return a positive Integer'
        end

        value
      end

      def generation_id
        value = @generation_source.call
        ProcessProgressProtocol.send(:validate_uint64!, value, :generation)
      end
    end
  end
end
