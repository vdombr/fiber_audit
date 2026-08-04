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
          FiberAudit::Runtime::SchedulerObserver.scheduler_replacing(thread: Thread.current) if Fiber.scheduler
          result = super
          if scheduler
            FiberAudit::Runtime::SchedulerObserver.scheduler_installed(
              scheduler: scheduler,
              thread: Thread.current
            )
          end
          result
        end
        # rubocop:enable Naming/AccessorMethodName
      end

      module SchedulerCloseHook
        def close(...)
          FiberAudit::Runtime::SchedulerObserver.scheduler_closing(thread: Thread.current)
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

        def scheduler_replacing(thread:)
          current_for_process&.scheduler_closing(thread: thread)
        end

        def scheduler_installed(scheduler:, thread:)
          observer = current_for_process
          return unless observer

          observer.scheduler_installed(scheduler: scheduler, thread: thread)
        end

        def scheduler_closing(thread:)
          current_for_process&.scheduler_closing(thread: thread)
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
      end

      def active_for_current_process?
        @active && owner_pid == Process.pid
      end

      def attach_existing!
        scheduler = Fiber.scheduler
        scheduler_installed(scheduler: scheduler, thread: Thread.current) if scheduler
        self
      end

      def scheduler_installed(scheduler:, thread:)
        return self unless active_for_current_process? && watchdog.enabled?

        install_close_hook!(scheduler)
        watchdog.scheduler_installed(thread: thread)
        self
      rescue StandardError
        watchdog.scheduler_unsupported(thread: thread)
        raise unless watchdog.fail_open?

        self
      end

      def scheduler_closing(thread:)
        watchdog.scheduler_closing(thread: thread) if active_for_current_process?
        self
      end

      def deactivate
        @active = false
        self
      end

      private

      def install_close_hook!(scheduler)
        singleton = scheduler.singleton_class
        singleton.prepend(SchedulerCloseHook) unless singleton.ancestors.include?(SchedulerCloseHook)
      end
    end
  end
end
