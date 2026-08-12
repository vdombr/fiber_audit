# frozen_string_literal: true

require 'fiber_audit/runtime/execution_context'

RSpec.describe FiberAudit::Runtime::ExecutionContext do
  after do
    described_class.reset!
  end

  describe '.current' do
    it 'defaults to :unknown when no context is set' do
      expect(described_class.current).to eq(:unknown)
    end

    it 'returns the current context after with' do
      described_class.with(:request) do
        expect(described_class.current).to eq(:request)
      end
    end

    it 'validates context against Context::ALL' do
      expect { described_class.with(:invalid_context) }.to raise_error(
        FiberAudit::RuntimeContractError,
        /execution_context is invalid/
      )
    end

    it 'accepts string contexts and normalizes to symbols' do
      described_class.with('request') do
        expect(described_class.current).to eq(:request)
      end
    end
  end

  describe '.with' do
    it 'restores the outer context after nested with' do
      described_class.with(:request) do
        expect(described_class.current).to eq(:request)
        described_class.with(:job) do
          expect(described_class.current).to eq(:job)
        end
        expect(described_class.current).to eq(:request)
      end
      expect(described_class.current).to eq(:unknown)
    end

    it 'restores context even when an exception is raised' do
      described_class.with(:request) do
        expect(described_class.current).to eq(:request)
        expect { described_class.with(:job) { raise StandardError } }.to raise_error(StandardError)
        expect(described_class.current).to eq(:request)
      end
    end

    it 'restores context even when Interrupt is raised' do
      described_class.with(:request) do
        expect(described_class.current).to eq(:request)
        expect { described_class.with(:job) { raise Interrupt } }.to raise_error(Interrupt)
        expect(described_class.current).to eq(:request)
      end
    end

    it 'bounds nesting depth and fails open when exceeded' do
      # Fill the stack to MAX_DEPTH
      depth = described_class.const_get(:MAX_DEPTH)
      contexts = Array.new(depth) { :request }

      # Build nested with calls
      execute_nested = lambda do |remaining, &block|
        if remaining.empty?
          block.call
        else
          described_class.with(remaining.first) do
            execute_nested.call(remaining[1..], &block)
          end
        end
      end

      execute_nested.call(contexts) do
        # At MAX_DEPTH, the next with should fail open and keep :request
        described_class.with(:job) do
          expect(described_class.current).to eq(:request) # Should still be :request, not :job
        end
        expect(described_class.current).to eq(:request)
      end
    end
  end

  describe 'fiber isolation' do
    it 'isolates context between fibers on the same thread' do
      described_class.with(:request) do
        fiber_context = nil
        fiber = Fiber.new do
          fiber_context = described_class.current
          Fiber.yield
        end
        fiber.resume
        expect(fiber_context).to eq(:unknown) # New fiber starts with :unknown
        expect(described_class.current).to eq(:request)
      end
    end

    it 'does not leak context to newly created fibers' do
      described_class.with(:request) do
        fiber = Fiber.new do
          expect(described_class.current).to eq(:unknown)
        end
        fiber.resume
      end
    end
  end

  describe 'thread isolation' do
    it 'isolates context between threads' do
      described_class.with(:request) do
        thread_context = nil
        thread = Thread.new do
          thread_context = described_class.current
          Thread.current.report_on_exception = false
        end
        thread.join
        expect(thread_context).to eq(:unknown)
        expect(described_class.current).to eq(:request)
      end
    end
  end

  describe '.reset!' do
    it 'clears the current context' do
      described_class.with(:request) do
        described_class.reset!
        expect(described_class.current).to eq(:unknown)
      end
    end

    it 'is idempotent' do
      described_class.reset!
      described_class.reset!
      expect(described_class.current).to eq(:unknown)
    end
  end

  describe '.after_fork!' do
    it 'clears the context after fork' do
      described_class.with(:request) do
        described_class.after_fork!
        expect(described_class.current).to eq(:unknown)
      end
    end
  end

  describe 'no application-visible keys' do
    it 'does not use Thread.current[] for storage' do
      described_class.with(:request) do
        # Check that no fiber-audit related keys are visible in Thread.current
        thread_keys = Thread.current.keys.select { |k| k.to_s.include?('fiber_audit') }
        expect(thread_keys).to be_empty
      end
    end
  end
end
