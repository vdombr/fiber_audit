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
      ].freeze

      def initialize(files:, semantic_index: nil)
        @files = Array(files)
        @sem = semantic_index
      end

      # Extract call sites from all files. Returns Result.
      # Never raises; collects parse errors per file.
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
          @nesting_stack = [] # Array of constant names (class/module nesting)
          @scope_stack = []   # Array of [class_or_module, method_name, method_kind]
          @assignment_scope = {} # flow-sensitive assignment tracking within current scope
        end

        def visit(node)
          return unless node

          case node
          when Prism::ClassNode
            visit_class(node)
          when Prism::ModuleNode
            visit_module(node)
          when Prism::DefNode
            visit_def(node)
          when Prism::CallNode
            visit_call(node)
          when Prism::LocalVariableWriteNode
            visit_assignment(node)
          else
            # Recurse into child nodes
            visit_children(node)
          end
        end

        private

        def visit_class(node)
          class_name = extract_constant_name(node.constant_path)
          @nesting_stack.push(class_name) if class_name

          # Track scope
          @scope_stack.push([class_name, nil, :instance])
          old_assignment_scope = @assignment_scope
          @assignment_scope = {}

          visit_children(node)

          @assignment_scope = old_assignment_scope
          @scope_stack.pop
          @nesting_stack.pop if class_name
        end

        def visit_module(node)
          module_name = extract_constant_name(node.constant_path)
          @nesting_stack.push(module_name) if module_name

          @scope_stack.push([module_name, nil, :module])
          old_assignment_scope = @assignment_scope
          @assignment_scope = {}

          visit_children(node)

          @assignment_scope = old_assignment_scope
          @scope_stack.pop
          @nesting_stack.pop if module_name
        end

        def visit_def(node)
          method_name = node.name.to_s
          method_kind = determine_method_kind(node)

          # Get enclosing class/module
          enclosing = current_enclosing_constant
          @scope_stack.push([enclosing, method_name, method_kind])

          # Reset assignment scope for method body
          old_assignment_scope = @assignment_scope
          @assignment_scope = {}

          visit_children(node)

          @assignment_scope = old_assignment_scope
          @scope_stack.pop
        end

        def visit_call(node)
          # Check if this is an assignment with .new or builder call
          check_assignment_propagation(node)

          # Extract call site
          call_site = build_call_site(node)
          @call_sites << call_site if call_site

          # Recurse into receiver and arguments
          visit(node.receiver) if node.receiver
          visit_arguments(node.arguments) if node.arguments
        end

        def visit_assignment(node)
          # Track local variable assignments for constructor propagation
          var_name = node.name.to_s
          value_node = node.value

          # Determine what's being assigned
          assigned_constant = extract_assigned_constant(value_node)

          if assigned_constant
            # Resolved constant assignment -> high confidence
            @assignment_scope[var_name] = {
              constant: assigned_constant,
              confidence: :high
            }
          elsif value_node.is_a?(Prism::CallNode) && value_node.name == :new
            # .new call -> try to resolve the receiver
            receiver_const = extract_constant_from_node(value_node.receiver)
            if receiver_const
              @assignment_scope[var_name] = {
                constant: receiver_const,
                confidence: :high
              }
            else
              # Builder call or unknown -> low confidence
              @assignment_scope[var_name] = {
                constant: nil,
                confidence: :low
              }
            end
          else
            # Unsupported reassignment -> invalidate
            @assignment_scope.delete(var_name)
          end

          visit(value_node)
        end

        def visit_children(node)
          node.compact_child_nodes.each do |child|
            visit(child)
          end
        rescue NoMethodError
          # Some nodes don't have compact_child_nodes
          node.child_nodes.compact.each { |child| visit(child) }
        end

        def visit_arguments(args)
          return unless args

          args.arguments.each do |arg|
            visit(arg)
          end
        end

        def build_call_site(node)
          receiver_source = extract_receiver_source(node)
          method_name = node.name
          arguments = extract_arguments(node)
          enclosing_symbol = build_enclosing_symbol
          nesting = @nesting_stack.dup
          receiver_constant = resolve_receiver_constant(node, receiver_source, nesting)

          # Build resolution string
          resolution = build_resolution(receiver_constant, receiver_source, method_name)

          # Determine confidence
          confidence = determine_confidence(receiver_constant, receiver_source, method_name)

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
            execution_context: nil, # WP-6 fills this
            resolution: resolution,
            confidence: confidence
          )
        end

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

        def extract_constant_name(node)
          return nil unless node

          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            # Build full path like "Net::HTTP"
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
            parts.join('::')
          else
            nil
          end
        end

        def extract_constant_from_node(node)
          return nil unless node

          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            extract_constant_name(node)
          else
            nil
          end
        end

        def extract_assigned_constant(value_node)
          case value_node
          when Prism::ConstantReadNode
            value_node.name.to_s
          when Prism::ConstantPathNode
            extract_constant_name(value_node)
          when Prism::CallNode
            # Check for Const.new pattern
            if value_node.name == :new && value_node.receiver
              extract_constant_from_node(value_node.receiver)
            else
              nil
            end
          else
            nil
          end
        end

        def check_assignment_propagation(node)
          # This is called for CallNode - we need to check if the receiver
          # is a local variable that was assigned a constant
          return unless node.receiver.is_a?(Prism::LocalVariableReadNode)

          var_name = node.receiver.name.to_s
          assignment_info = @assignment_scope[var_name]

          return unless assignment_info

          # Store this for use in resolve_receiver_constant
          node.instance_variable_set(:@fiber_audit_assignment_info, assignment_info)
        end

        def resolve_receiver_constant(node, receiver_source, nesting)
          return nil unless receiver_source

          # Check if receiver is a local variable with assignment info
          if node.receiver.is_a?(Prism::LocalVariableReadNode)
            assignment_info = node.instance_variable_get(:@fiber_audit_assignment_info)
            if assignment_info
              return assignment_info[:constant]
            end
          end

          # Try semantic index first
          if @semantic_index
            resolved = @semantic_index.resolve_constant(receiver_source, nesting: nesting)
            return resolved.name if resolved
          end

          # Try well-known constants table
          if WELL_KNOWN_CONSTANTS.include?(receiver_source)
            return receiver_source
          end

          # Check if it's a simple constant reference
          if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
            const_name = extract_constant_from_node(node.receiver)
            if const_name && WELL_KNOWN_CONSTANTS.include?(const_name)
              return const_name
            end
          end

          nil
        end

        def build_resolution(receiver_constant, receiver_source, method_name)
          if receiver_constant
            "#{receiver_constant}.#{method_name}"
          elsif receiver_source
            "#{receiver_source}.#{method_name}"
          end
        end

        def determine_confidence(receiver_constant, receiver_source, method_name)
          if receiver_constant
            :high
          elsif receiver_source
            :low
          else
            # Bare/implicit call
            :unknown
          end
        end

        def build_enclosing_symbol
          return nil if @scope_stack.empty?

          # Find the most recent method in scope stack
          @scope_stack.reverse.each do |const, method, kind|
            if method
              case kind
              when :instance
                return "#{const}##{method}"
              when :class
                return "#{const}.#{method}"
              end
            end
          end

          # No method, just class/module
          const, = @scope_stack.last
          const
        end

        def determine_method_kind(node)
          # Check if this is a class method (def self.method_name)
          if node.receiver
            if node.receiver.is_a?(Prism::SelfNode)
              :class
            else
              :instance # def obj.method is rare but treat as instance
            end
          else
            :instance
          end
        end

        def current_enclosing_constant
          # Find the most recent class/module in nesting
          @nesting_stack.last
        end
      end
    end
  end
end
