# frozen_string_literal: true

require 'prism'
require_relative 'call_site'

module FiberAudit
  module Static
    # Extracts CallSite objects from Ruby source files using Prism.
    # Performs single-pass parsing per file with receiver inference.
    class CallSiteExtractor
      # Error from parsing a single file
      ParseError = Data.define(:path, :message, :line)

      # Result of extraction across multiple files
      Result = Data.define(:call_sites, :parse_errors)

      # Well-known constants that can be resolved without semantic index
      WELL_KNOWN_CONSTANTS = %w[
        Kernel
        Open3
        IO
        Process
        Thread
        Mutex
        ConditionVariable
        Monitor
        MonitorMixin
        TCPSocket
        TCPServer
        UDPSocket
        UNIXSocket
        UNIXServer
        Socket
        IPSocket
        Net::HTTP
        URI
        OpenURI
        ActiveSupport::CurrentAttributes
        File
        Dir
        Pathname
        Redis
        Net::SMTP
        Net::FTP
        Net::IMAP
      ].to_set.freeze

      def initialize(files:, semantic_index: nil)
        @files = Array(files)
        @sem = semantic_index
      end

      # Extract call sites from all files. Returns Result.
      # Never raises; collects parse errors per file.
      # Maintains deterministic order: files processed in provided order.
      def call
        call_sites = []
        parse_errors = []

        @files.each do |file_path|
          extract_from_file(file_path, call_sites, parse_errors)
        end

        Result.new(call_sites: call_sites, parse_errors: parse_errors)
      end

      private

      def extract_from_file(file_path, call_sites, parse_errors)
        # Read file once
        source = File.read(file_path)

        # Parse once with Prism
        parse_result = Prism.parse(source)

        # Collect parse errors and skip traversal if any
        if parse_result.errors.any?
          parse_result.errors.each do |error|
            parse_errors << ParseError.new(
              path: file_path,
              message: error.message,
              line: error.location&.start_line
            )
          end
          return
        end

        # Walk the AST
        visitor = ASTVisitor.new(
          file_path: file_path,
          source: source,
          semantic_index: @sem
        )
        visitor.visit(parse_result.value)

        call_sites.concat(visitor.call_sites)
      rescue Errno::ENOENT => e
        parse_errors << ParseError.new(
          path: file_path,
          message: "No such file or directory: #{file_path}",
          line: nil
        )
      rescue StandardError => e
        parse_errors << ParseError.new(
          path: file_path,
          message: e.message,
          line: nil
        )
      end

      # Internal visitor that walks the AST and extracts call sites
      class ASTVisitor
        attr_reader :call_sites

        def initialize(file_path:, source:, semantic_index:)
          @file_path = file_path
          @source = source
          @semantic_index = semantic_index
          @call_sites = []

          # Scope tracking stacks
          @nesting_stack = []        # Array of constant names (class/module nesting)
          @scope_stack = []          # Array of [class_or_module, method_name, method_kind]
          @in_singleton_class = false # Track if inside `class << self`

          # Assignment tracking: local variable -> {constant:, confidence:}
          # Scoped per method; no ivars attached to Prism nodes.
          @assignment_scope = {}
        end

        def visit(node)
          return unless node

          case node
          when Prism::ClassNode
            visit_class(node)
          when Prism::ModuleNode
            visit_module(node)
          when Prism::SingletonClassNode
            visit_singleton_class(node)
          when Prism::DefNode
            visit_def(node)
          when Prism::IfNode
            visit_branching(node)
          when Prism::UnlessNode
            visit_branching(node)
          when Prism::CaseNode
            visit_branching(node)
          when Prism::CallNode
            visit_call(node)
          when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode
            visit_assignment(node)
          else
            visit_children(node)
          end
        end

        private

        # --- Class/Module/SingletonClass visitors ---

        def visit_class(node)
          # Extract fully qualified constant path components for nesting
          names = extract_nesting_names(node.constant_path)
          names.each { |n| @nesting_stack.push(n) }

          @scope_stack.push([names.last, nil, :instance])
          saved_scope = @assignment_scope
          @assignment_scope = {}

          visit_children(node)

          @assignment_scope = saved_scope
          @scope_stack.pop
          names.size.times { @nesting_stack.pop }
        end

        def visit_module(node)
          names = extract_nesting_names(node.constant_path)
          names.each { |n| @nesting_stack.push(n) }

          @scope_stack.push([names.last, nil, :module])
          saved_scope = @assignment_scope
          @assignment_scope = {}

          visit_children(node)

          @assignment_scope = saved_scope
          @scope_stack.pop
          names.size.times { @nesting_stack.pop }
        end

        def visit_singleton_class(node)
          # `class << self` or `class << expr` - mark as singleton for def method_kind
          prev_singleton = @in_singleton_class
          @in_singleton_class = true
          visit_children(node)
          @in_singleton_class = prev_singleton
        end

        def visit_def(node)
          method_name = node.name.to_s
          method_kind = determine_method_kind(node)

          enclosing = current_enclosing_constant
          @scope_stack.push([enclosing, method_name, method_kind])

          saved_scope = @assignment_scope
          @assignment_scope = {}

          visit_children(node)

          @assignment_scope = saved_scope
          @scope_stack.pop
        end

        # --- Branching visitors (if/unless/case) ---
        # Assignments in branches cannot leak to outer scope conservatively.

        def visit_branching(node)
          # Snapshot current assignments before entering branches
          pre_scope = @assignment_scope.dup

          # Visit all child nodes to collect call sites in branches
          # but restore assignment scope afterward
          visit_children(node)

          # Restore pre-branch scope: any assignments made inside branches
          # are discarded. Variables that existed before and were not
          # reassigned remain; new variables from branches don't leak.
          @assignment_scope = pre_scope
        end

        # --- Call node visitor ---

        def visit_call(node)
          # Extract call site with local assignment tracking (no ivars on nodes)
          call_site = build_call_site(node)
          @call_sites << call_site if call_site

          # Recurse into receiver and arguments
          visit(node.receiver) if node.receiver
          visit(node.arguments) if node.arguments
        end

        def visit_assignment(node)
          var_name = node.name.to_s
          value_node = node.value

          # Determine what's being assigned
          assigned_info = compute_assignment_info(value_node)

          if assigned_info
            @assignment_scope[var_name] = assigned_info
          else
            # Unsupported assignment (not .new, not a constant, not a call) -> invalidate
            @assignment_scope.delete(var_name)
          end

          visit(value_node)
        end

        def visit_children(node)
          node.compact_child_nodes.each do |child|
            visit(child)
          end
        rescue NoMethodError
          node.child_nodes.compact.each { |child| visit(child) }
        end

        # --- Assignment info computation ---
        # Returns {constant: String|nil, confidence: Symbol} or nil to invalidate.

        def compute_assignment_info(value_node)
          case value_node
          when Prism::CallNode
            compute_call_assignment_info(value_node)
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            # Direct constant assignment: `x = SomeConst`
            const_name = extract_constant_from_node(value_node)
            if const_name && resolved_constant?(const_name)
              { constant: const_name, confidence: :high }
            end
          else
            nil
          end
        end

        def compute_call_assignment_info(call_node)
          if call_node.name == :new && call_node.receiver
            # Constructor call: `x = SomeConst.new(...)`
            receiver_const = extract_constant_from_node(call_node.receiver)
            if receiver_const && resolved_constant?(receiver_const)
              { constant: receiver_const, confidence: :high }
            elsif receiver_const
              # Unresolved constant.new -> textual low, do NOT fabricate high
              { constant: receiver_const, confidence: :low }
            else
              # Bare .new with no constant receiver -> low
              { constant: nil, confidence: :low }
            end
          else
            # Builder/other call: `x = build_something`
            { constant: nil, confidence: :low }
          end
        end

        # Check if a constant name is resolvable (well-known or semantic index)
        def resolved_constant?(const_name)
          return true if WELL_KNOWN_CONSTANTS.include?(const_name)
          return false unless @semantic_index

          begin
            @semantic_index.resolve_constant(const_name, nesting: @nesting_stack.dup) != nil
          rescue StandardError
            false
          end
        end

        # --- Call site building ---

        def build_call_site(node)
          receiver_source = extract_receiver_source(node)
          method_name = node.name
          arguments = extract_arguments(node)
          enclosing_symbol = build_enclosing_symbol
          nesting = @nesting_stack.dup
          receiver_constant = resolve_receiver_constant(node, receiver_source)

          resolution = build_resolution(receiver_constant, receiver_source, method_name)
          confidence = determine_confidence(receiver_constant, receiver_source)

          CallSite.new(
            path: @file_path,
            line: node.location.start_line,
            column: node.location.start_column,
            receiver_source: receiver_source,
            receiver_constant: receiver_constant,
            method_name: method_name,
            arguments: arguments,
            enclosing_symbol: enclosing_symbol,
            nesting: nesting,
            execution_context: nil,
            resolution: resolution,
            confidence: confidence
          )
        end

        # --- Receiver extraction ---

        def extract_receiver_source(node)
          return nil unless node.receiver

          receiver = node.receiver
          loc = receiver.location
          @source[loc.start_offset...loc.end_offset]
        end

        def extract_arguments(node)
          return [] unless node.arguments

          node.arguments.arguments.map do |arg|
            loc = arg.location
            @source[loc.start_offset...loc.end_offset]
          end
        end

        # --- Constant resolution ---

        def resolve_receiver_constant(node, receiver_source)
          return nil unless receiver_source

          # 1. Direct constructor chain: `Thread.new.join` -> infer Thread
          if node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :new
            chain_const = extract_chain_constructor(node.receiver)
            return chain_const if chain_const
          end

          # 2. Local variable with tracked assignment
          if node.receiver.is_a?(Prism::LocalVariableReadNode)
            var_name = node.receiver.name.to_s
            info = @assignment_scope[var_name]
            return info[:constant] if info && info[:confidence] == :high
          end

          # 3. Direct constant reference: `Open3.capture3`
          if node.receiver.is_a?(Prism::ConstantReadNode) ||
             node.receiver.is_a?(Prism::ConstantPathNode)
            const_name = extract_constant_from_node(node.receiver)
            return const_name if const_name && resolved_constant?(const_name)
          end

          # 4. Try semantic index for other receiver sources
          if @semantic_index
            begin
              resolved = @semantic_index.resolve_constant(
                receiver_source,
                nesting: @nesting_stack.dup
              )
              return resolved.name if resolved
            rescue StandardError
              # Semantic adapter exception: rescue per receiver, not per file
              nil
            end
          end

          # 5. Well-known constants table
          return receiver_source if WELL_KNOWN_CONSTANTS.include?(receiver_source)

          nil
        end

        # Extract constructor constant from a direct chain like Thread.new.join
        def extract_chain_constructor(new_call)
          return nil unless new_call.is_a?(Prism::CallNode) && new_call.name == :new

          if new_call.receiver.is_a?(Prism::ConstantReadNode) ||
             new_call.receiver.is_a?(Prism::ConstantPathNode)
            const_name = extract_constant_from_node(new_call.receiver)
            return const_name if const_name && resolved_constant?(const_name)
          end

          nil
        end

        # --- Constant name extraction ---

        def extract_constant_from_node(node)
          return nil unless node

          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            build_constant_path_string(node)
          else
            nil
          end
        end

        # Build fully qualified constant path string like "Net::HTTP"
        def build_constant_path_string(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
          parts.join('::')
        end

        # Extract nesting names from a constant path node.
        # For `class Outer::Inner`, returns ['Outer', 'Inner'].
        # For `class Foo`, returns ['Foo'].
        def extract_nesting_names(node)
          return [] unless node

          case node
          when Prism::ConstantReadNode
            [node.name.to_s]
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
            parts
          else
            []
          end
        end

        # --- Resolution and confidence ---

        def build_resolution(receiver_constant, receiver_source, method_name)
          if receiver_constant
            "#{receiver_constant}.#{method_name}"
          elsif receiver_source
            "#{receiver_source}.#{method_name}"
          end
        end

        def determine_confidence(receiver_constant, receiver_source)
          if receiver_constant
            :high
          elsif receiver_source
            :low
          else
            :unknown
          end
        end

        # --- Enclosing symbol ---
        # Calls in class/module body without a method have enclosing_symbol nil.

        def build_enclosing_symbol
          return nil if @scope_stack.empty?

          # Find the most recent method in scope stack
          @scope_stack.reverse.each do |const, method, kind|
            next unless method

            prefix = const || ''
            case kind
            when :instance
              return prefix.empty? ? "##{method}" : "#{prefix}##{method}"
            when :class
              return prefix.empty? ? ".#{method}" : "#{prefix}.#{method}"
            end
          end

          # No method found (call in class/module body) -> nil
          nil
        end

        # --- Method kind determination ---

        def determine_method_kind(node)
          # def self.method -> class method
          if node.receiver.is_a?(Prism::SelfNode)
            :class
          # Inside `class << self; def method` -> class method
          elsif @in_singleton_class
            :class
          else
            :instance
          end
        end

        def current_enclosing_constant
          @nesting_stack.last
        end
      end
    end
  end
end
