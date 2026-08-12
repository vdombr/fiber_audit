# frozen_string_literal: true

require 'fiber_audit/runtime/execution_context'

RSpec.describe FiberAudit::Runtime::ExecutionContext do
  after do
    described_class.clear!
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

    it 'exposes :unknown when MAX_DEPTH is exceeded' do
      depth = described_class.const_get(:MAX_DEPTH)
      contexts = Array.new(depth) { :request }

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
        described_class.with(:job) do
          expect(described_class.current).to eq(:unknown)
        end
        expect(described_class.current).to eq(:request)
      end
    end

    it 'returns the value of the block' do
      result = described_class.with(:request) { 42 }
      expect(result).to eq(42)
    end

    it 'restores context when block returns early' do
      described_class.with(:request) do
        described_class.with(:job) do
          next
        end
        expect(described_class.current).to eq(:request)
      end
    end
  end

  describe 'fiber propagation' do
    it 'propagates current context to child fibers' do
      described_class.with(:request) do
        child_context = nil
        Fiber.new { child_context = described_class.current }.resume
        expect(child_context).to eq(:request)
        expect(described_class.current).to eq(:request)
      end
    end

    it 'child fiber overrides do not alter parent context' do
      described_class.with(:request) do
        Fiber.new do
          described_class.with(:job) do
            expect(described_class.current).to eq(:job)
          end
        end.resume
        expect(described_class.current).to eq(:request)
      end
    end

    it 'child fiber created without context starts with :unknown' do
      child_context = nil
      Fiber.new { child_context = described_class.current }.resume
      expect(child_context).to eq(:unknown)
    end

    it 'propagates context through multiple levels of fiber nesting' do
      described_class.with(:request) do
        grandchild_context = nil
        Fiber.new do
          Fiber.new do
            grandchild_context = described_class.current
          end.resume
        end.resume
        expect(grandchild_context).to eq(:request)
      end
    end

    it 'child fiber sees context changes made before its creation' do
      child_contexts = []
      described_class.with(:request) do
        Fiber.new do
          child_contexts << described_class.current
          described_class.with(:job) do
            child_contexts << described_class.current
          end
          child_contexts << described_class.current
        end.resume
        expect(described_class.current).to eq(:request)
      end
      expect(child_contexts).to eq(%i[request job request])
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

    it 'new threads start with :unknown context' do
      described_class.with(:request) do
        contexts = []
        threads = 3.times.map do
          Thread.new { contexts << described_class.current }
        end
        threads.each(&:join)
        expect(contexts).to all(eq(:unknown))
      end
    end
  end

  describe '.clear!' do
    it 'clears the current context' do
      described_class.with(:request) do
        described_class.clear!
        expect(described_class.current).to eq(:unknown)
      end
    end

    it 'is idempotent' do
      described_class.clear!
      described_class.clear!
      expect(described_class.current).to eq(:unknown)
    end

    it 'is not undone by enclosing with ensure' do
      described_class.with(:request) do
        described_class.clear!
        expect(described_class.current).to eq(:unknown)
      end
      expect(described_class.current).to eq(:unknown)
    end

    it 'is not undone by multiple levels of enclosing with' do
      described_class.with(:request) do
        described_class.with(:job) do
          described_class.with(:callback) do
            described_class.clear!
            expect(described_class.current).to eq(:unknown)
          end
          expect(described_class.current).to eq(:unknown)
        end
        expect(described_class.current).to eq(:unknown)
      end
      expect(described_class.current).to eq(:unknown)
    end

    it 'affects only the current fiber' do
      described_class.with(:request) do
        Fiber.new do
          described_class.clear!
          expect(described_class.current).to eq(:unknown)
        end.resume
        expect(described_class.current).to eq(:request)
      end
    end

    it 'allows new with blocks after clear' do
      described_class.with(:request) do
        described_class.clear!
        described_class.with(:job) do
          expect(described_class.current).to eq(:job)
        end
        expect(described_class.current).to eq(:unknown)
      end
      expect(described_class.current).to eq(:unknown)
    end
  end

  describe '.reset!' do
    it 'is an alias for clear!' do
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

    it 'is not undone by enclosing with ensure' do
      described_class.with(:request) do
        described_class.reset!
      end
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

    it 'allows new context after after_fork!' do
      described_class.after_fork!
      described_class.with(:request) do
        expect(described_class.current).to eq(:request)
      end
    end
  end

  describe 'no application-visible keys' do
    it 'does not use Thread.current[] for storage' do
      described_class.with(:request) do
        thread_keys = Thread.current.keys.select { |k| k.to_s.include?('fiber_audit') }
        expect(thread_keys).to be_empty
      end
    end

    it 'uses Fiber storage which is not visible in Thread.current' do
      described_class.with(:request) do
        expect(Thread.current[:__fiber_audit_execution_context_frame__]).to be_nil
        expect(Thread.current[:__fiber_audit_execution_context_pid__]).to be_nil
      end
    end
  end

  describe 'Frame immutability' do
    it 'frames are frozen' do
      frame = nil
      described_class.with(:request) do
        frame = described_class.send(:current_frame)
      end
      expect(frame).to be_frozen if frame
    end

    it 'frames cannot be mutated' do
      frame = nil
      described_class.with(:request) do
        frame = described_class.send(:current_frame)
      end
      expect { frame.context = :job }.to raise_error(FrozenError) if frame
    end
  end
end
