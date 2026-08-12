# frozen_string_literal: true

require 'tmpdir'
require 'fiber_audit/runtime/rails_integration'

RSpec.describe FiberAudit::Runtime::RailsIntegration do
  after do
    # Reset the module state between tests
    described_class.deactivate if described_class.current
  end

  describe '.activate without Rails constants' do
    it 'returns nil-friendly integration with no hooks installed' do
      integration = described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      expect(integration).to be_a(described_class)
      expect(integration).to be_active_for_current_process
    end

    it 'rescan! is a no-op without Rails constants' do
      integration = described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      expect { integration.rescan! }.not_to raise_error
    end
  end

  describe 'controller hook with stub constant' do
    before do
      stub_const('ActionController::Metal', Class.new do
        def process_action(*args, **kwargs, &block)
          block&.call(*args, **kwargs)
        end
      end)
    end

    it 'wraps process_action with :request context' do
      integration = described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      controller = ActionController::Metal.new
      observed = nil

      FiberAudit::Runtime::ExecutionContext.with(:middleware) do
        controller.process_action do
          observed = FiberAudit::Runtime::ExecutionContext.current
          :response
        end
      end

      expect(observed).to eq(:request)
      expect(integration).to be_active_for_current_process
    end

    it 'preserves return value and keyword arguments' do
      stub_const('ActionController::Metal', Class.new do
        def process_action(name:, **kwargs)
          { name: name, kwargs: kwargs }
        end
      end)
      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)

      controller = ActionController::Metal.new
      result = controller.process_action(name: 'show', params: { id: 1 })

      expect(result).to eq({ name: 'show', kwargs: { params: { id: 1 } } })
    end

    it 'preserves exact exception identity' do
      error = StandardError.new('application error')
      stub_const('ActionController::Metal', Class.new do
        define_method(:process_action) { raise error }
      end)
      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)

      controller = ActionController::Metal.new
      expect { controller.process_action }.to(raise_error { |raised| expect(raised).to equal(error) })
    end

    it 'preserves block forwarding' do
      stub_const('ActionController::Metal', Class.new do
        def process_action(&block)
          block.call(:captured)
        end
      end)
      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)

      controller = ActionController::Metal.new
      result = controller.process_action { |value| "got #{value}" }
      expect(result).to eq('got captured')
    end

    it 'controller callbacks inherit :request context' do
      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      callback_context = nil

      FiberAudit::Runtime::ExecutionContext.with(:middleware) do
        controller = ActionController::Metal.new
        controller.process_action do
          # Simulate a controller callback running inside process_action
          callback_context = FiberAudit::Runtime::ExecutionContext.current
        end
      end

      expect(callback_context).to eq(:request)
    end
  end

  describe 'job hook with stub constant' do
    before do
      stub_const('ActiveJob::Base', Class.new do
        def perform_now(*_args, **_kwargs)
          :performed
        end
      end)
    end

    it 'wraps perform_now with :job context' do
      integration = described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      job = ActiveJob::Base.new
      observed = nil

      FiberAudit::Runtime::ExecutionContext.with(:middleware) do
        job.perform_now
        observed = FiberAudit::Runtime::ExecutionContext.current
      end

      # NOTE: observed is captured outside the block, so it should be :middleware
      # Let's capture inside instead
      ActiveJob::Base.new
      captured_during_perform = nil
      stub_const('ActiveJob::Base', Class.new do
        define_method(:perform_now) do
          captured_during_perform = FiberAudit::Runtime::ExecutionContext.current
          :performed
        end
      end)
      integration.rescan!
      job_with_capture = ActiveJob::Base.new

      FiberAudit::Runtime::ExecutionContext.with(:middleware) do
        job_with_capture.perform_now
      end

      expect(captured_during_perform).to eq(:job)
    end

    it 'restores outer context after perform_now' do
      stub_const('ActiveJob::Base', Class.new do
        define_method(:perform_now) do
          FiberAudit::Runtime::ExecutionContext.current
          :performed
        end
      end)
      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)

      FiberAudit::Runtime::ExecutionContext.with(:middleware) do
        job = ActiveJob::Base.new
        result = job.perform_now
        expect(result).to eq(:performed)
        expect(FiberAudit::Runtime::ExecutionContext.current).to eq(:middleware)
      end
    end
  end

  describe 'cable hook with stub constant' do
    before do
      stub_const('ActionCable::Channel::Base', Class.new do
        def dispatch_action(*_args, **_kwargs)
          :dispatched
        end
      end)
    end

    it 'wraps dispatch_action with :websocket context' do
      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      captured = nil

      stub_const('ActionCable::Channel::Base', Class.new do
        define_method(:dispatch_action) do
          captured = FiberAudit::Runtime::ExecutionContext.current
          :dispatched
        end
      end)
      FiberAudit::Runtime::RailsIntegration.current.rescan!

      channel = ActionCable::Channel::Base.new
      FiberAudit::Runtime::ExecutionContext.with(:request) do
        channel.dispatch_action
      end

      expect(captured).to eq(:websocket)
    end
  end

  describe 'middleware' do
    it 'wraps downstream call with :middleware context' do
      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      captured = nil
      downstream = lambda do |_env|
        captured = FiberAudit::Runtime::ExecutionContext.current
        [200, {}, ['ok']]
      end

      middleware = described_class::Middleware.new(downstream)
      FiberAudit::Runtime::ExecutionContext.with(:unknown) do
        result = middleware.call({})
        expect(result).to eq([200, {}, ['ok']])
      end

      expect(captured).to eq(:middleware)
    end

    it 'passes through when integration is not active' do
      integration = described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      integration.deactivate!
      captured = nil
      downstream = lambda do |_env|
        captured = FiberAudit::Runtime::ExecutionContext.current
        [200, {}, ['ok']]
      end

      middleware = described_class::Middleware.new(downstream)
      FiberAudit::Runtime::ExecutionContext.with(:request) do
        middleware.call({})
      end

      expect(captured).to eq(:request)
    end
  end

  describe 'idempotence' do
    it 'installs hooks only once when activated multiple times' do
      stub_const('ActionController::Metal', Class.new do
        define_method(:process_action) do
          FiberAudit::Runtime::ExecutionContext.current
        end
      end)

      # Count ancestors before any activation
      before_count = ActionController::Metal.ancestors.count { |a| a.name&.include?('ControllerHook') }

      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      after_first = ActionController::Metal.ancestors.count { |a| a.name&.include?('ControllerHook') }

      # Rescan should not add more hooks
      FiberAudit::Runtime::RailsIntegration.current.rescan!
      after_rescan = ActionController::Metal.ancestors.count { |a| a.name&.include?('ControllerHook') }

      expect(after_first - before_count).to eq(1)
      expect(after_rescan).to eq(after_first)
    end
  end

  describe 'deactivation' do
    it 'makes wrappers inert after deactivation' do
      stub_const('ActionController::Metal', Class.new do
        define_method(:process_action) do
          FiberAudit::Runtime::ExecutionContext.current
        end
      end)

      integration = described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)
      integration.deactivate!

      controller = ActionController::Metal.new
      FiberAudit::Runtime::ExecutionContext.with(:middleware) do
        result = controller.process_action
        expect(result).to eq(:middleware) # Should not be :request
      end
    end
  end

  describe 'fork/PID mismatch' do
    it 'makes wrappers inert after PID change' do
      skip 'fork is unavailable' unless Process.respond_to?(:fork)

      stub_const('ActionController::Metal', Class.new do
        define_method(:process_action) do
          FiberAudit::Runtime::ExecutionContext.current
        end
      end)

      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)

      read_pipe, write_pipe = IO.pipe
      pid = fork do
        read_pipe.close
        # In child, ExecutionContext resets but RailsIntegration sees PID mismatch
        result = nil
        FiberAudit::Runtime::ExecutionContext.with(:middleware) do
          # Controller wrapper should be inert due to PID mismatch
          controller = ActionController::Metal.new
          result = controller.process_action
        end
        write_pipe.write(result.to_s)
        write_pipe.close
        exit!
      end

      write_pipe.close
      child_result = read_pipe.read
      read_pipe.close
      Process.wait(pid)

      # Child's RailsIntegration is inert (PID mismatch), so context stays :middleware
      expect(child_result).to eq('middleware')
    end
  end

  describe 'fail-open on installation errors' do
    it 'does not propagate errors from hook installation' do
      # Simulate a constant that raises on prepend
      bad_class = Class.new
      allow(bad_class).to receive(:prepend).and_raise(RuntimeError, 'prepend failed')
      stub_const('ActionController::Metal', bad_class)

      expect { described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext) }.not_to raise_error
    end
  end

  describe 'late loading' do
    it 'rescans automatically after a successful require' do
      stub_const('ActionCable', Module.new)
      stub_const('ActionCable::Channel', Module.new)
      described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)

      Dir.mktmpdir do |directory|
        feature = File.join(directory, "fiber_audit_late_cable_#{Process.pid}.rb")
        File.write(feature, <<~RUBY)
          class ActionCable::Channel::Base
            def dispatch_action
              FiberAudit::Runtime::ExecutionContext.current
            end
          end
        RUBY

        expect(require(feature)).to be(true)
        expect(ActionCable::Channel::Base.new.dispatch_action).to eq(:websocket)
      end
    end

    it 'installs hooks via rescan! when constants appear after activation' do
      # Activate before the constant exists
      integration = described_class.activate(context_store: FiberAudit::Runtime::ExecutionContext)

      # Now define the constant
      stub_const('ActionCable::Channel::Base', Class.new do
        define_method(:dispatch_action) do
          FiberAudit::Runtime::ExecutionContext.current
        end
      end)

      # Rescan should install the hook
      integration.rescan!

      captured = nil
      channel = ActionCable::Channel::Base.new
      FiberAudit::Runtime::ExecutionContext.with(:request) do
        channel.dispatch_action
      end
      # The dispatch_action returns :dispatched, but we need to capture inside
      # Let's re-define with capture
      stub_const('ActionCable::Channel::Base', Class.new do
        define_method(:dispatch_action) do
          captured = FiberAudit::Runtime::ExecutionContext.current
          :dispatched
        end
      end)
      integration.rescan!

      channel = ActionCable::Channel::Base.new
      FiberAudit::Runtime::ExecutionContext.with(:request) do
        channel.dispatch_action
      end

      expect(captured).to eq(:websocket)
    end
  end
end
