# frozen_string_literal: true

require_relative 'clock'
require_relative 'event'
require_relative 'recorder'
require_relative 'synchronization_graph_policy'
require_relative 'synchronization_identity_registry'

module FiberAudit
  module Runtime
    # Graph owns a bounded, synchronized state machine and its evidence events.
    # rubocop:disable Metrics/ClassLength
    class SynchronizationGraph
      WaitHandle = Data.define(:pid, :sequence, :actor_id, :resource_id)
      Ownership = Data.define(:actor_id, :depth)
      WaitEdge = Data.define(:handle, :resource_id)
      Snapshot = Data.define(:owners, :waits, :identity_count, :truncated) do
        def initialize(owners:, waits:, identity_count:, truncated:)
          super(owners: owners.dup.freeze, waits: waits.dup.freeze,
                identity_count: identity_count, truncated: truncated)
        end

        def truncated? = truncated
      end
      STATES = %i[active disabled unsupported failed stopped].freeze
      attr_reader :policy, :state

      def initialize(policy:, recorder:, clock: Clock.new, pid_source: Process.method(:pid), supported: true)
        validate_dependencies!(policy, recorder, clock, pid_source, supported)
        @policy = policy
        @recorder = recorder
        @clock = clock
        @pid_source = pid_source
        @supported = supported
        @owner_pid = current_pid
        @mutex = Mutex.new
        @identities = SynchronizationIdentityRegistry.new(capacity: policy.max_identities, pid_source: pid_source)
        reset_state!
        emit_events([state_event])
      rescue StandardError => e
        fail_graph!(e)
      end

      def active? = state == :active
      def enabled? = policy.enabled?

      # State mutation and corresponding evidence emission remain atomic under the graph mutex.
      # rubocop:disable Metrics/AbcSize
      def begin_wait(resource:, operation:, actor: Fiber.current, thread: Thread.current)
        return unless active?

        events = []
        handle = @mutex.synchronize do
          ensure_current_process_locked!
          actor_id, resource_id = identities_for(actor, resource, events)
          next unless actor_id && resource_id

          unless @waits.key?(actor_id) || @waits.size < policy.max_wait_edges
            add_truncation_event(events, :wait_edges)
            next
          end
          @wait_sequence += 1
          handle = WaitHandle.new(pid: @owner_pid, sequence: @wait_sequence,
                                  actor_id: actor_id, resource_id: resource_id)
          @waits[actor_id] = WaitEdge.new(handle: handle, resource_id: resource_id)
          owner = @owners[resource_id]
          events << build_event(kind: :sync_wait_started, operation: operation, actor: actor, thread: thread,
                                measurements: base_measurements(actor_id, resource_id).merge(
                                  wait_sequence: handle.sequence, owner_known: !owner.nil?,
                                  owner_actor_id: owner&.actor_id, wait_edge_count: @waits.size
                                ))
          cycle_actors = cycle_actor_count(actor_id, events)
          events << cycle_event(cycle_actors) if cycle_actors
          handle
        end
        emit_events(events)
        handle
      rescue StandardError => e
        fail_graph!(e)
      end
      # rubocop:enable Metrics/AbcSize

      # State mutation and corresponding evidence emission remain atomic under the graph mutex.
      # rubocop:disable Metrics/AbcSize
      def acquired(resource:, operation:, wait: nil, actor: Fiber.current, thread: Thread.current)
        return false unless active?

        events = []
        acquired = @mutex.synchronize do
          ensure_current_process_locked!
          actor_id, resource_id = identities_for(actor, resource, events)
          next false unless actor_id && resource_id

          completed = remove_wait(wait, actor_id, resource_id)
          events << wait_completed_event(completed, operation, actor, thread, true) if completed
          ownership = @owners[resource_id]
          if ownership.nil? && @owners.size >= policy.max_resources
            add_truncation_event(events, :resources)
            next false
          end
          depth = ownership&.actor_id == actor_id ? ownership.depth + 1 : 1
          replaced = !ownership.nil? && ownership.actor_id != actor_id
          @owners[resource_id] = Ownership.new(actor_id: actor_id, depth: depth)
          events << build_event(kind: :sync_acquired, operation: operation, actor: actor, thread: thread,
                                measurements: base_measurements(actor_id, resource_id).merge(
                                  ownership_depth: depth, recursive: depth > 1,
                                  ownership_replaced: replaced
                                ))
          true
        end
        emit_events(events)
        acquired
      rescue StandardError => e
        fail_graph!(e)
        false
      end
      # rubocop:enable Metrics/AbcSize

      def wait_completed(wait:, operation:, acquired: false, actor: Fiber.current, thread: Thread.current)
        return false unless active?
        raise RuntimeContractError, 'acquired must be a Boolean' unless [true, false].include?(acquired)

        event = @mutex.synchronize do
          ensure_current_process_locked!
          actor_id = @identities.id_for(actor)
          next unless actor_id

          completed = remove_wait(wait, actor_id, wait&.resource_id)
          wait_completed_event(completed, operation, actor, thread, acquired) if completed
        end
        emit_events([event].compact)
        !event.nil?
      rescue StandardError => e
        fail_graph!(e)
        false
      end

      def released(resource:, operation:, actor: Fiber.current, thread: Thread.current)
        return false unless active?

        event = @mutex.synchronize do
          ensure_current_process_locked!
          actor_id = @identities.id_for(actor)
          resource_id = @identities.id_for(resource)
          next unless actor_id && resource_id

          ownership = @owners[resource_id]
          known = ownership&.actor_id == actor_id
          depth = nil
          if known
            depth = ownership.depth - 1
            if depth.zero?
              @owners.delete(resource_id)
            else
              @owners[resource_id] =
                Ownership.new(actor_id: actor_id, depth: depth)
            end
          end
          build_event(kind: :sync_released, operation: operation, actor: actor, thread: thread,
                      measurements: base_measurements(actor_id, resource_id).merge(
                        ownership_known: known, ownership_depth: depth
                      ))
        end
        emit_events([event].compact)
        event&.measurements&.fetch(:ownership_known, event.measurements['ownership_known'])
      rescue StandardError => e
        fail_graph!(e)
        false
      end

      def snapshot
        @mutex.synchronize do
          ensure_current_process_locked!
          Snapshot.new(owners: @owners, waits: @waits.transform_values(&:resource_id),
                       identity_count: @identities.size,
                       truncated: !@truncation_reasons.empty? || @identities.truncated?)
        end
      end

      def stop
        @mutex.synchronize do
          @owners.clear
          @waits.clear
          @identities.clear!
          @state = :stopped
        end
        self
      rescue StandardError => e
        fail_graph!(e)
        self
      end

      private

      def validate_dependencies!(candidate_policy, candidate_recorder, candidate_clock, pids, supported)
        unless candidate_policy.is_a?(SynchronizationGraphPolicy)
          raise RuntimeContractError,
                'policy must be a FiberAudit::Runtime::SynchronizationGraphPolicy'
        end
        unless candidate_recorder.is_a?(Recorder)
          raise RuntimeContractError,
                'recorder must be a FiberAudit::Runtime::Recorder'
        end
        raise RuntimeContractError, 'clock must be a FiberAudit::Runtime::Clock' unless candidate_clock.is_a?(Clock)
        raise RuntimeContractError, 'pid_source must respond to call' unless pids.respond_to?(:call)
        raise RuntimeContractError, 'supported must be a Boolean' unless [true, false].include?(supported)
      end

      def reset_state!
        @owners = {}
        @waits = {}
        @wait_sequence = 0
        @cycle_sequence = 0
        @truncation_reasons = {}
        @state = if policy.enabled?
                   @supported ? :active : :unsupported
                 else
                   :disabled
                 end
      end

      def ensure_current_process_locked!
        pid = current_pid
        return if pid == @owner_pid

        @owner_pid = pid
        @identities.after_fork!
        reset_state!
      end

      def identities_for(actor, resource, events)
        actor_id = @identities.id_for(actor)
        resource_id = @identities.id_for(resource)
        add_truncation_event(events, :identities) unless actor_id && resource_id
        [actor_id, resource_id]
      end

      def remove_wait(handle, actor_id, resource_id)
        return unless handle.is_a?(WaitHandle) && handle.pid == @owner_pid
        return unless handle.actor_id == actor_id && handle.resource_id == resource_id

        edge = @waits[actor_id]
        return unless edge&.handle == handle

        @waits.delete(actor_id)
        handle
      end

      def cycle_actor_count(start_actor_id, events)
        resource_id = @waits[start_actor_id]&.resource_id
        visited = {}
        actors = 0
        policy.max_cycle_depth.times do
          ownership = @owners[resource_id]
          return unless ownership

          actors += 1
          return actors if ownership.actor_id == start_actor_id
          return if visited[ownership.actor_id]

          visited[ownership.actor_id] = true
          resource_id = @waits[ownership.actor_id]&.resource_id
          return unless resource_id
        end
        add_truncation_event(events, :cycle_depth)
        nil
      end

      def state_event
        build_event(kind: :"sync_graph_#{state}", measurements: {
                      enabled: policy.enabled?, supported: @supported,
                      max_identities: policy.max_identities, max_resources: policy.max_resources,
                      max_wait_edges: policy.max_wait_edges, max_cycle_depth: policy.max_cycle_depth
                    })
      end

      def cycle_event(actor_count)
        @cycle_sequence += 1
        build_event(kind: :sync_cycle_candidate, measurements: {
                      cycle_sequence: @cycle_sequence, cycle_actor_count: actor_count,
                      cycle_edge_count: actor_count * 2, wait_edge_count: @waits.size,
                      graph_truncated: !@truncation_reasons.empty? || @identities.truncated?
                    })
      end

      def wait_completed_event(handle, operation, actor, thread, acquired)
        build_event(kind: :sync_wait_completed, operation: operation, actor: actor, thread: thread,
                    measurements: base_measurements(handle.actor_id, handle.resource_id).merge(
                      wait_sequence: handle.sequence, acquired: acquired, wait_edge_count: @waits.size
                    ))
      end

      def base_measurements(actor_id, resource_id)
        { sync_actor_id: actor_id, sync_resource_id: resource_id,
          graph_truncated: !@truncation_reasons.empty? || @identities.truncated? }
      end

      def add_truncation_event(events, reason)
        return if @truncation_reasons[reason]

        @truncation_reasons[reason] = true
        events << build_event(kind: :sync_graph_truncated, measurements: {
                                identities_exhausted: reason == :identities, resources_exhausted: reason == :resources,
                                wait_edges_exhausted: reason == :wait_edges, cycle_depth_exhausted: reason == :cycle_depth,
                                identity_count: @identities.size, resource_count: @owners.size, wait_edge_count: @waits.size
                              })
      end

      def build_event(kind:, measurements:, operation: nil, actor: nil, thread: nil)
        Event.new(kind: kind, source: :synchronization_graph, occurred_at: @clock.wall_time,
                  monotonic_ns: @clock.monotonic_ns, operation: operation,
                  thread_id: thread&.object_id, fiber_id: actor&.object_id, measurements: measurements)
      end

      def emit_events(events)
        events.each { |event| @recorder.record_control { event } }
      end

      def fail_graph!(error)
        @state = :failed
        @recorder&.internal_error!
        raise error if @recorder && !@recorder.session.policy.fail_open?

        nil
      end

      def current_pid
        value = @pid_source.call
        return value if value.is_a?(Integer) && value.positive?

        raise RuntimeContractError, 'pid source must return a positive Integer'
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
