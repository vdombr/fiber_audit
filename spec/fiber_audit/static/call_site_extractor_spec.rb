# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/call_site_extractor'

RSpec.describe FiberAudit::Static::CallSiteExtractor do
  let(:fixtures_path) { File.expand_path('../../fixtures/call_sites', __dir__) }

  describe 'Data structures' do
    it 'defines ParseError with path, message, line' do
      expect(described_class::ParseError.members).to eq(%i[path message line])
    end

    it 'defines Result with call_sites, parse_errors' do
      expect(described_class::Result.members).to eq(%i[call_sites parse_errors])
    end
  end

  describe '#initialize' do
    it 'accepts files and optional semantic_index' do
      extractor = described_class.new(files: ['test.rb'])
      expect(extractor).to be_a(described_class)
    end

    it 'wraps single file in array' do
      extractor = described_class.new(files: 'test.rb')
      result = extractor.call
      expect(result).to be_a(described_class::Result)
    end
  end

  describe '#call' do
    it 'returns Result with call_sites and parse_errors' do
      extractor = described_class.new(files: [])
      result = extractor.call

      expect(result).to be_a(described_class::Result)
      expect(result.call_sites).to be_an(Array)
      expect(result.parse_errors).to be_an(Array)
    end

    context 'with simple_class fixture' do
      let(:file) { File.join(fixtures_path, 'simple_class.rb') }
      let(:result) { described_class.new(files: [file]).call }

      it 'extracts call sites with correct method names as Symbols' do
        methods = result.call_sites.map(&:method_name)
        expect(methods).to include(:puts, :capture3)
      end

      it 'tracks enclosing_symbol correctly' do
        puts_call = result.call_sites.find { |cs| cs.method_name == :puts }
        expect(puts_call.enclosing_symbol).to eq('SimpleClass#simple_method')

        capture3_call = result.call_sites.find { |cs| cs.method_name == :capture3 }
        expect(capture3_call.enclosing_symbol).to eq('SimpleClass#simple_method')
      end

      it 'resolves well-known constants with high confidence' do
        capture3_call = result.call_sites.find { |cs| cs.method_name == :capture3 }
        expect(capture3_call.receiver_constant).to eq('Open3')
        expect(capture3_call.confidence).to eq(:high)
        expect(capture3_call.resolution).to eq('Open3.capture3')
      end

      it 'marks bare calls as unknown confidence' do
        puts_call = result.call_sites.find { |cs| cs.method_name == :puts }
        expect(puts_call.receiver_source).to be_nil
        expect(puts_call.receiver_constant).to be_nil
        expect(puts_call.confidence).to eq(:unknown)
        expect(puts_call.resolution).to be_nil
      end

      it 'extracts exact source for arguments' do
        capture3_call = result.call_sites.find { |cs| cs.method_name == :capture3 }
        expect(capture3_call.arguments).to eq(["'ls'"])
      end

      it 'tracks nesting' do
        capture3_call = result.call_sites.find { |cs| cs.method_name == :capture3 }
        expect(capture3_call.nesting).to eq(['SimpleClass'])
      end

      it 'preserves path exactly as supplied' do
        result.call_sites.each do |cs|
          expect(cs.path).to eq(file)
        end
      end
    end

    context 'with class_methods fixture' do
      let(:file) { File.join(fixtures_path, 'class_methods.rb') }
      let(:result) { described_class.new(files: [file]).call }

      it 'distinguishes instance and class method enclosing symbols' do
        thread_call = result.call_sites.find { |cs| cs.method_name == :new }
        expect(thread_call.enclosing_symbol).to eq('ClassMethodsExample#instance_method')

        capture3_call = result.call_sites.find { |cs| cs.method_name == :capture3 }
        expect(capture3_call.enclosing_symbol).to eq('ClassMethodsExample.class_method')

        waitall_call = result.call_sites.find { |cs| cs.method_name == :waitall }
        expect(waitall_call.enclosing_symbol).to eq('ClassMethodsExample.singleton_block_method')

        select_call = result.call_sites.find { |cs| cs.method_name == :select }
        expect(select_call.enclosing_symbol).to eq('ClassMethodsExample.explicit_receiver_method')
      end

      it 'tracks method_kind correctly' do
        thread_call = result.call_sites.find { |cs| cs.method_name == :new }
        expect(thread_call.method_name).to eq(:new)

        capture3_call = result.call_sites.find { |cs| cs.method_name == :capture3 }
        expect(capture3_call.method_name).to eq(:capture3)
      end
    end

    context 'with assignment_propagation fixture' do
      let(:file) { File.join(fixtures_path, 'assignment_propagation.rb') }
      let(:result) { described_class.new(files: [file]).call }

      it 'propagates constant from Redis.new assignment with high confidence' do
        get_call = result.call_sites.find { |cs| cs.method_name == :get }
        expect(get_call.receiver_constant).to eq('Redis')
        expect(get_call.confidence).to eq(:high)
      end

      it 'propagates constant through multiple calls in same scope' do
        set_call = result.call_sites.find { |cs| cs.method_name == :set }
        expect(set_call.receiver_constant).to eq('Redis')
        expect(set_call.confidence).to eq(:high)
      end

      it 'marks builder call results as low confidence' do
        execute_call = result.call_sites.find { |cs| cs.method_name == :execute }
        expect(execute_call.receiver_constant).to be_nil
        expect(execute_call.confidence).to eq(:low)
      end
    end

    context 'with nested_constants fixture' do
      let(:file) { File.join(fixtures_path, 'nested_constants.rb') }
      let(:result) { described_class.new(files: [file]).call }

      it 'resolves nested constants like Net::HTTP' do
        get_call = result.call_sites.find { |cs| cs.method_name == :get }
        expect(get_call.receiver_constant).to eq('Net::HTTP')
        expect(get_call.confidence).to eq(:high)
        expect(get_call.resolution).to eq('Net::HTTP.get')
      end

      it 'tracks fully qualified lexical nesting and enclosing symbols' do
        get_call = result.call_sites.find { |cs| cs.method_name == :get }

        expect(get_call.nesting).to eq(%w[OuterModule OuterModule::InnerClass])
        expect(get_call.enclosing_symbol).to eq('OuterModule::InnerClass#nested_method')
      end
    end

    context 'with constructor_chain fixture' do
      let(:file) { File.join(fixtures_path, 'constructor_chain.rb') }
      let(:result) { described_class.new(files: [file]).call }

      it 'propagates Thread from assignment-based Thread.new' do
        join_calls = result.call_sites.select { |cs| cs.method_name == :join }
        expect(join_calls).not_to be_empty

        join_call = join_calls.first
        expect(join_call.receiver_constant).to eq('Thread')
        expect(join_call.confidence).to eq(:high)
      end

      it 'propagates Mutex from assignment-based Mutex.new' do
        sync_calls = result.call_sites.select { |cs| cs.method_name == :synchronize }
        expect(sync_calls).not_to be_empty

        sync_call = sync_calls.first
        expect(sync_call.receiver_constant).to eq('Mutex')
        expect(sync_call.confidence).to eq(:high)
      end

      it 'infers Thread from direct Thread.new.join chain' do
        join_calls = result.call_sites.select { |cs| cs.method_name == :join }
        # Should have at least 2 join calls (assignment-based + direct)
        expect(join_calls.size).to be >= 2

        direct_join = join_calls.find { |cs| cs.receiver_source&.start_with?('Thread.new') }
        expect(direct_join).not_to be_nil
        expect(direct_join.receiver_constant).to eq('Thread')
        expect(direct_join.confidence).to eq(:high)
      end

      it 'infers Mutex from direct Mutex.new.synchronize chain' do
        sync_calls = result.call_sites.select { |cs| cs.method_name == :synchronize }
        expect(sync_calls.size).to be >= 2

        direct_sync = sync_calls.find { |cs| cs.receiver_source == 'Mutex.new' }
        expect(direct_sync).not_to be_nil
        expect(direct_sync.receiver_constant).to eq('Mutex')
        expect(direct_sync.confidence).to eq(:high)
      end

      it 'propagates Thread from a Thread.current assignment' do
        access = result.call_sites.find { |cs| cs.method_name == :thread_variable_get }

        expect(access.receiver_source).to eq('current_thread')
        expect(access.receiver_constant).to eq('Thread')
        expect(access.confidence).to eq(:high)
      end

      it 'extracts calls from attached block bodies' do
        select_call = result.call_sites.find { |cs| cs.method_name == :select }

        expect(select_call.receiver_constant).to eq('IO')
        expect(select_call.enclosing_symbol).to eq('ConstructorChain#attached_block_body')
      end
    end

    context 'with explicit blocking Fiber regions' do
      def extract_source(source, semantic_index: nil)
        Dir.mktmpdir do |directory|
          path = File.join(directory, 'fiber_context.rb')
          File.write(path, source)
          result = described_class.new(files: [path], semantic_index: semantic_index).call
          expect(result.parse_errors).to be_empty
          return result.call_sites
        end
      end

      it 'propagates the nearest context through nested attached blocks' do
        sites = extract_source(<<~RUBY)
          Fiber.blocking do
            Process.wait
            Fiber.new(blocking: true) { IO.select([], [], [], nil) }
          end
        RUBY

        outer = sites.find { |site| site.method_name == :blocking }
        inner = sites.find { |site| site.method_name == :new }
        wait = sites.find { |site| site.method_name == :wait }
        select = sites.find { |site| site.method_name == :select }

        expect(wait.fiber_context).to equal(outer.fiber_context)
        expect(inner.fiber_context.kind).to eq(:fiber_new)
        expect(select.fiber_context).to equal(inner.fiber_context)
        expect(select.fiber_context).not_to equal(outer.fiber_context)
      end

      it 'does not invent contexts for dynamic, false, receiverless, or blockless forms' do
        sites = extract_source(<<~RUBY)
          value = true
          Fiber.new(blocking: false) { Process.wait }
          Fiber.new(blocking: value) { Process.wait }
          blocking { Process.wait }
          Fiber.new(blocking: true)
        RUBY

        expect(sites.map(&:fiber_context).compact).to be_empty
      end
    end

    context 'with malformed fixture' do
      let(:file) { File.join(fixtures_path, 'malformed.rb') }
      let(:result) { described_class.new(files: [file]).call }

      it 'collects parse errors and skips traversal' do
        expect(result.parse_errors).not_to be_empty
        expect(result.parse_errors.first).to be_a(described_class::ParseError)
        expect(result.parse_errors.first.path).to eq(file)
        expect(result.call_sites).to be_empty
      end

      it 'includes error message and line' do
        error = result.parse_errors.first
        expect(error.message).to be_a(String)
        expect(error.line).to be_a(Integer).or be_nil
      end
    end

    context 'with scope_isolation fixture' do
      let(:file) { File.join(fixtures_path, 'scope_isolation.rb') }
      let(:result) { described_class.new(files: [file]).call }

      it 'does not leak assignments across methods' do
        puts_calls = result.call_sites.select { |cs| cs.method_name == :puts }
        expect(puts_calls.size).to eq(1)

        # The puts in method_two should not see client from method_one
        puts_call = puts_calls.first
        expect(puts_call.receiver_constant).to be_nil
        expect(puts_call.confidence).to eq(:unknown)
      end
    end

    context 'with reassignment fixture' do
      let(:file) { File.join(fixtures_path, 'reassignment.rb') }
      let(:result) { described_class.new(files: [file]).call }

      it 'extracts all four get calls' do
        get_calls = result.call_sites.select { |cs| cs.method_name == :get }
        expect(get_calls.size).to eq(4)
      end

      it 'first get after Redis.new has high confidence' do
        get_calls = result.call_sites.select { |cs| cs.method_name == :get }
        first_get = get_calls[0]

        expect(first_get.receiver_constant).to eq('Redis')
        expect(first_get.confidence).to eq(:high)
        expect(first_get.arguments).to eq(["'key1'"])
      end

      it 'second get after builder reassignment has low confidence' do
        get_calls = result.call_sites.select { |cs| cs.method_name == :get }
        second_get = get_calls[1]

        # After reassignment to build_client (a builder), tracking is invalidated
        expect(second_get.receiver_constant).to be_nil
        expect(second_get.confidence).to eq(:low)
        expect(second_get.receiver_source).to eq('client')
        expect(second_get.arguments).to eq(["'key2'"])
      end

      it 'third get after conditional assignment has low confidence' do
        get_calls = result.call_sites.select { |cs| cs.method_name == :get }
        third_get = get_calls[2]

        # After if/else with branch-local assignments, tracking is invalidated conservatively
        expect(third_get.receiver_constant).to be_nil
        expect(third_get.confidence).to eq(:low)
        expect(third_get.receiver_source).to eq('client')
        expect(third_get.arguments).to eq(["'key3'"])
      end

      it 'does not leak an assignment into a sibling branch' do
        get_calls = result.call_sites.select { |cs| cs.method_name == :get }
        sibling_get = get_calls[3]

        expect(sibling_get.receiver_constant).to be_nil
        expect(sibling_get.receiver_source).to eq('sibling_client')
        expect(sibling_get.confidence).to eq(:low)
      end
    end

    context 'with multiple files' do
      let(:files) do
        [
          File.join(fixtures_path, 'simple_class.rb'),
          File.join(fixtures_path, 'class_methods.rb')
        ]
      end
      let(:result) { described_class.new(files: files).call }

      it 'processes all files' do
        paths = result.call_sites.map(&:path).uniq
        expect(paths).to match_array(files)
      end

      it 'maintains deterministic ordering' do
        # Files should be processed in the order provided
        first_file_calls = result.call_sites.select { |cs| cs.path == files[0] }
        expect(first_file_calls).not_to be_empty
      end
    end

    context 'with non-existent file' do
      let(:result) { described_class.new(files: ['nonexistent.rb']).call }

      it 'collects error and continues' do
        expect(result.parse_errors).not_to be_empty
        expect(result.parse_errors.first.message).to include('No such file')
      end
    end

    context 'with semantic index' do
      let(:file) { File.join(fixtures_path, 'simple_class.rb') }
      let(:semantic_index) do
        instance_double('FiberAudit::Static::SemanticIndex')
      end

      before do
        allow(semantic_index).to receive(:resolve_constant).and_return(nil)
      end

      it 'tries semantic index before well-known table' do
        extractor = described_class.new(files: [file], semantic_index: semantic_index)
        result = extractor.call

        # Should still resolve Open3 from well-known table
        capture3_call = result.call_sites.find { |cs| cs.method_name == :capture3 }
        expect(capture3_call.receiver_constant).to eq('Open3')
      end
    end

    context 'single read/parse guarantee' do
      it 'reads and parses each file only once' do
        file = File.join(fixtures_path, 'simple_class.rb')

        # Mock File.read to count calls
        read_count = 0
        allow(File).to receive(:read).and_wrap_original do |original, *args|
          read_count += 1 if args.first == file
          original.call(*args)
        end

        extractor = described_class.new(files: [file])
        extractor.call

        expect(read_count).to eq(1)
      end
    end
  end

  describe 'well-known constants' do
    it 'includes common blocking operations' do
      well_known = described_class::WELL_KNOWN_CONSTANTS

      expect(well_known).to include('Open3')
      expect(well_known).to include('Thread')
      expect(well_known).to include('Mutex')
      expect(well_known).to include('Net::HTTP')
      expect(well_known).to include('Redis')
      expect(well_known).to include('IO')
      expect(well_known).to include('Process')
      expect(well_known).to include('Socket')
    end
  end

  describe 'confidence levels' do
    it 'uses :high for resolved constants' do
      file = File.join(fixtures_path, 'simple_class.rb')
      result = described_class.new(files: [file]).call

      open3_call = result.call_sites.find { |cs| cs.method_name == :capture3 }
      expect(open3_call.confidence).to eq(:high)
    end

    it 'uses :low for textual receivers' do
      file = File.join(fixtures_path, 'assignment_propagation.rb')
      result = described_class.new(files: [file]).call

      execute_call = result.call_sites.find { |cs| cs.method_name == :execute }
      expect(execute_call.confidence).to eq(:low)
    end

    it 'uses :unknown for bare implicit calls' do
      file = File.join(fixtures_path, 'simple_class.rb')
      result = described_class.new(files: [file]).call

      puts_call = result.call_sites.find { |cs| cs.method_name == :puts }
      expect(puts_call.confidence).to eq(:unknown)
    end
  end

  describe 'resolution strings' do
    it 'formats as receiver_constant.method_name when resolved' do
      file = File.join(fixtures_path, 'nested_constants.rb')
      result = described_class.new(files: [file]).call

      get_call = result.call_sites.find { |cs| cs.method_name == :get }
      expect(get_call.resolution).to eq('Net::HTTP.get')
    end

    it 'formats as receiver_source.method_name when not resolved' do
      file = File.join(fixtures_path, 'assignment_propagation.rb')
      result = described_class.new(files: [file]).call

      execute_call = result.call_sites.find { |cs| cs.method_name == :execute }
      expect(execute_call.resolution).to eq('conn.execute')
    end

    it 'is nil for bare calls' do
      file = File.join(fixtures_path, 'simple_class.rb')
      result = described_class.new(files: [file]).call

      puts_call = result.call_sites.find { |cs| cs.method_name == :puts }
      expect(puts_call.resolution).to be_nil
    end
  end

  describe 'Location helper' do
    it 'provides location objects for all call sites' do
      file = File.join(fixtures_path, 'simple_class.rb')
      result = described_class.new(files: [file]).call

      result.call_sites.each do |cs|
        location = cs.location
        expect(location).to be_a(FiberAudit::Location)
        expect(location.path).to eq(file)
        expect(location.line).to be_a(Integer)
        expect(location.column).to be_a(Integer)
      end
    end
  end
end
