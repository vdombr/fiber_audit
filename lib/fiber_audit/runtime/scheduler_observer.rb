# frozen_string_literal: true

require_relative 'watchdog'

module FiberAudit
  module Runtime
    # Explicit-runtime-only hooks for schedulers installed after RUBYOPT boot.
    class SchedulerObserver
      module FiberHook
        # Ruby's scheduler API fixes this writer-like method name.
        # rubocop:disable Naming/AccessorMethodName
        def set_scheduler(scheduler)
          previous = Fiber.scheduler
          result = super
          current = Fiber.scheduler
          FiberAudit::Runtime::SchedulerObserver.scheduler_changed(
            previous: previous,
            current: current,
            thread: Thread.current
          )
          result
        end
        # rubocop:enable Naming/AccessorMethodName
      end

      module SchedulerCloseHook
        def close(...)
          FiberAudit::Runtime::SchedulerObserver.scheduler_closing(
            scheduler: self,
            thread: Thread.current
          )
          super
        end
      end

      class << self
        def activate(watchdog:)
          raise RuntimeContractError, 'watchdog must be a FiberAudit::Runtime::Watchdog' unless watchdog.is_a?(Watchdog)

          install_fiber_hook!
          observer = new(watchdog: watchdog)
          @current = observer
          observer.attach_existing!
          observer
        end

        def scheduler_changed(previous:, current:, thread:)
          observer = current_for_process
          return unless observer

          observer.scheduler_changed(previous: previous, current: current, thread: thread)
        end

        def scheduler_closing(thread:, scheduler: nil)
          current_for_process&.scheduler_closing(scheduler: scheduler, thread: thread)
        end

        def deactivate(observer)
          @current = nil if @current.equal?(observer)
          observer.deactivate
        end

        private

        def current_for_process
          observer = @current
          return observer if observer&.active_for_current_process?

          nil
        end

        def install_fiber_hook!
          singleton = Fiber.singleton_class
          singleton.prepend(FiberHook) unless singleton.ancestors.include?(FiberHook)
        end
      end

      attr_reader :watchdog, :owner_pid

      def initialize(watchdog:)
        @watchdog = watchdog
        @owner_pid = Process.pid
        @active = true
        @mutex = Mutex.new
        @schedulers = {}
      end

      def active_for_current_process?
        @active && owner_pid == Process.pid
      end

      def attach_existing!
        scheduler = Fiber.scheduler
        scheduler_installed(scheduler: scheduler, thread: Thread.current) if scheduler
        self
      end

      def scheduler_changed(previous:, current:, thread:)
        return self unless active_for_current_process?

        scheduler_closing(scheduler: previous, thread: thread) if previous && !previous.equal?(current)
        scheduler_installed(scheduler: current, thread: thread) if current
        self
      end

      def scheduler_installed(scheduler:, thread:)
        return self unless active_for_current_process? && watchdog.enabled?
        return self unless track_scheduler(scheduler, thread)

        install_close_hook!(scheduler)
        watchdog.scheduler_installed(thread: thread)
        self
      rescue StandardError
        watchdog.scheduler_unsupported(thread: thread)
        raise unless watchdog.fail_open?

        self
      end

      def scheduler_closing(thread:, scheduler: nil)
        return self unless active_for_current_process?
        return self unless untrack_scheduler(scheduler, thread)

        watchdog.scheduler_closing(thread: thread)
        self
      end

      def deactivate
        @active = false
        @mutex.synchronize { @schedulers.clear }
        self
      end

      private

      def install_close_hook!(scheduler)
        singleton = scheduler.singleton_class
        singleton.prepend(SchedulerCloseHook) unless singleton.ancestors.include?(SchedulerCloseHook)
      end

      def track_scheduler(scheduler, thread)
        @mutex.synchronize do
          key = thread.object_id
          return false if @schedulers[key].equal?(scheduler)

          @schedulers[key] = scheduler
          true
        end
      end

      def untrack_scheduler(scheduler, thread)
        @mutex.synchronize do
          key = thread.object_id
          tracked = @schedulers[key]
          return false unless tracked
          return false if scheduler && !tracked.equal?(scheduler)

          @schedulers.delete(key)
          true
        end
      end
    end
  end
end
