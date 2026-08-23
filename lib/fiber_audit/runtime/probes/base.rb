# frozen_string_literal: true

require_relative '../active_operations'
require_relative '../clock'
require_relative '../event'
require_relative '../execution_context'
require_relative '../rails_integration'
require_relative '../recorder'
require_relative '../redactor'
require_relative '../scheduler_evidence_classifier'
require_relative '../scheduler_snapshot'

module FiberAudit
  module Runtime
    module Probes
      # Shared behavior-preserving observation boundary for targeted wrappers.
      # rubocop:disable Metrics/ClassLength
      class Base
        SOURCE = :targeted_probe
        MAX_CALLSITE_FRAMES = 32
        INTERNAL_PATH = File.expand_path('../..', __dir__).freeze
        ORIGINAL_MUTEX_SYNCHRONIZE = Mutex.instance_method(:synchronize)

        Observation = Data.define(
          :operation,
          :started_monotonic_ns,
          :location,
          :handle,
          :thread_id,
          :fiber_id,
          :measurements,
          :execution_context,
          :scheduler_snapshot
        )

        attr_reader :recorder, :clock, :redactor, :active_operations, :owner_pid, :execution_context_store

        def initialize(recorder:, clock:, redactor:, active_operations:, execution_context_store: nil,
                       pid_source: Process.method(:pid))
          validate_dependencies!(recorder, clock, redactor, active_operations, execution_context_store, pid_source)
          @recorder = recorder
          @clock = clock
          @redactor = redactor
          @active_operations = active_operations
          @execution_context_store = execution_context_store
          @pid_source = pid_source
          @owner_pid = current_pid
          @active = true
        end

        def observe(operation:, measurements: {}, emit_start: false, measurement_builder: nil)
          return yield unless active_for_current_process?
          return yield if guarded?

          observation = begin
            prepare_observation(operation, measurements)
          rescue StandardError => e
            instrumentation_failure(e)
          end
          return yield unless observation

          with_guard { emit_start_observation(observation) } if emit_start
          completed = false
          result = nil
          begin
            result = yield
            completed = true
            result
          ensure
            finalize_observation(observation, completed: completed, result: result, measurement_builder: measurement_builder)
          end
        end

        def with_guard
          self.class.enter_guard
          yield
        ensure
          self.class.exit_guard
        end

        def deactivate
          @active = false
          self
        end

        def active_for_current_process?
          @active && owner_pid == current_pid
        rescue StandardError
          false
        end

        def fail_open?
          recorder.session.policy.fail_open?
        end

        def instrumentation_failure(error)
          account_internal_error
          raise error unless fail_open?

          nil
        end

        private

        def validate_dependencies!(candidate_recorder, candidate_clock, candidate_redactor, operations, context_store, pids)
          raise RuntimeContractError, 'recorder must be a Runtime::Recorder' unless candidate_recorder.is_a?(Recorder)
          raise RuntimeContractError, 'clock must be a Runtime::Clock' unless candidate_clock.is_a?(Clock)
          raise RuntimeContractError, 'redactor must be a Runtime::Redactor' unless candidate_redactor.is_a?(Redactor)
          unless operations.is_a?(ActiveOperations)
            raise RuntimeContractError, 'active_operations must be Runtime::ActiveOperations'
          end
          if context_store && !context_store.respond_to?(:current)
            raise RuntimeContractError, 'execution_context_store must respond to current'
          end
          raise RuntimeContractError, 'pid_source must respond to call' unless pids.respond_to?(:call)
        end

        def prepare_observation(operation, measurements)
          # The block keeps all preparation under one recursion guard.
          # rubocop:disable Metrics/BlockLength
          with_guard do
            canonical_operation = Validation.operation(operation)
            normalized_measurements = normalize_measurements(measurements)
            started_ns = clock.monotonic_ns
            location = project_callsite
            next unless location

            thread = Thread.current
            fiber = Fiber.current
            captured_context = capture_execution_context
            captured_scheduler_snapshot = capture_scheduler_snapshot
            handle = active_operations.register(
              operation: canonical_operation,
              monotonic_ns: started_ns,
              location: location,
              execution_context: captured_context,
              thread: thread,
              fiber: fiber,
              scheduler_snapshot: captured_scheduler_snapshot
            )
            Observation.new(
              operation: canonical_operation,
              started_monotonic_ns: started_ns,
              location: location,
              handle: handle,
              thread_id: thread.object_id,
              fiber_id: fiber.object_id,
              measurements: normalized_measurements,
              execution_context: captured_context,
              scheduler_snapshot: captured_scheduler_snapshot
            )
          end
          # rubocop:enable Metrics/BlockLength
        end

        def capture_execution_context
          return Context::UNKNOWN unless execution_context_store

          execution_context_store.current
        rescue StandardError
          Context::UNKNOWN
        end

        def capture_scheduler_snapshot
          SchedulerSnapshotCapture.capture
        end

        def emit_start_observation(observation)
          emit_observation(:operation_started, observation, monotonic_ns: observation.started_monotonic_ns)
        rescue StandardError => e
          with_guard { active_operations.finish(observation.handle) } if observation.handle && !fail_open?
          instrumentation_failure(e)
        end

        def finalize_observation(observation, completed:, result:, measurement_builder:)
          error = nil
          begin
            if active_for_current_process?
              with_guard do
                ended_ns = clock.monotonic_ns
                if ended_ns < observation.started_monotonic_ns
                  raise RuntimeSafetyError, 'probe monotonic clock moved backwards'
                end

                measurements = completed_measurements(observation, completed, result, measurement_builder)
                emit_observation(
                  completed ? :operation_completed : :operation_aborted,
                  observation,
                  monotonic_ns: ended_ns,
                  duration_ns: ended_ns - observation.started_monotonic_ns,
                  measurements: measurements
                )
              end
            end
          rescue StandardError => e
            error = e
          ensure
            begin
              with_guard { active_operations.finish(observation.handle) } if observation.handle
            rescue StandardError => e
              error ||= e
            end
          end

          return unless error

          account_internal_error
          raise error if completed && !fail_open?
        end

        def completed_measurements(observation, completed, result, builder)
          values = observation.measurements.dup
          if completed && builder
            generated = builder.call(result)
            raise RuntimeContractError, 'measurement_builder must return a Hash' unless generated.is_a?(Hash)

            values.merge!(generated)
          end
          values[:operation_sequence] = observation.handle&.sequence
          enrich_scheduler_evidence(values, observation)
        end

        def emit_observation(kind, observation, monotonic_ns:, duration_ns: nil, measurements: nil)
          values = measurements || observation.measurements.merge(operation_sequence: observation.handle&.sequence)
          values = enrich_scheduler_evidence(values.dup, observation)
          recorder.record do
            Event.new(
              kind: kind,
              source: SOURCE,
              occurred_at: clock.wall_time,
              monotonic_ns: monotonic_ns,
              duration_ns: duration_ns,
              operation: observation.operation,
              location: observation.location,
              execution_context: observation.execution_context,
              thread_id: observation.thread_id,
              fiber_id: observation.fiber_id,
              measurements: values
            )
          end
        end

        def enrich_scheduler_evidence(values, observation)
          snapshot = observation.scheduler_snapshot
          values.merge!(snapshot.to_measurements) if snapshot
          values.merge!(
            SchedulerEvidenceClassifier.measurements(
              operation: observation.operation,
              scheduler_snapshot: snapshot
            )
          )
          values
        end

        def normalize_measurements(value)
          raise RuntimeContractError, 'probe measurements must be a Hash' unless value.is_a?(Hash)

          value.dup.freeze
        end

        def project_callsite
          caller_locations(0, MAX_CALLSITE_FRAMES)&.each do |frame|
            paths = frame_paths(frame)
            next if paths.any? { |path| internal_path?(path) }

            return paths.filter_map { |path| safe_location(frame, path) }.first
          rescue StandardError
            return nil
          end
          nil
        end

        def frame_paths(frame)
          candidates = [frame.absolute_path, frame.path].compact.filter_map do |path|
            next unless path.is_a?(String) && !path.start_with?('-', '<')

            File.absolute_path?(path) ? File.expand_path(path) : File.expand_path(path, redactor.root)
          end
          candidates.uniq
        end

        def internal_path?(path)
          path == INTERNAL_PATH || path.start_with?("#{INTERNAL_PATH}#{File::SEPARATOR}")
        end

        def safe_location(frame, path)
          location = redactor.location(path: path, line: frame.lineno, column: nil)
          return if Location::SENTINELS.include?(location.path)

          location
        end

        class << self
          def guarded?
            state = guard_state
            key = guard_key
            ORIGINAL_MUTEX_SYNCHRONIZE.bind_call(state.fetch(:mutex)) do
              state.fetch(:depths).fetch(key, 0).positive?
            end
          end

          def enter_guard
            state = guard_state
            key = guard_key
            ORIGINAL_MUTEX_SYNCHRONIZE.bind_call(state.fetch(:mutex)) do
              depths = state.fetch(:depths)
              depths[key] = depths.fetch(key, 0) + 1
            end
          end

          def exit_guard
            state = guard_state
            key = guard_key
            ORIGINAL_MUTEX_SYNCHRONIZE.bind_call(state.fetch(:mutex)) do
              depths = state.fetch(:depths)
              depth = depths.fetch(key, 1) - 1
              depth.positive? ? depths[key] = depth : depths.delete(key)
            end
          end

          private

          def guard_state
            pid = Process.pid
            return @guard_state if @guard_pid == pid && @guard_state

            @guard_pid = pid
            @guard_state = { mutex: Mutex.new, depths: {} }
          end

          def guard_key
            [Thread.current.object_id, Fiber.current.object_id]
          end
        end

        def guarded?
          self.class.guarded?
        end

        def account_internal_error
          with_guard { recorder.internal_error! unless recorder.disabled? }
        rescue StandardError
          nil
        end

        def current_pid
          value = @pid_source.call
          return value if value.is_a?(Integer) && value.positive?

          raise RuntimeContractError, 'pid_source must return a positive Integer'
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
