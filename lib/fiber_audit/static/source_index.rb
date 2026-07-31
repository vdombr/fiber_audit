# frozen_string_literal: true

require 'prism'

module FiberAudit
  module Static
    # Prism-based call-site extraction
    # Rubydex tracks semantic relationships but doesn't expose method names in references
    # This class fills that gap by walking the AST with Prism
    class SourceIndex
      attr_reader :files, :call_sites, :parse_errors

      def initialize(files:)
        @files = Array(files)
        @call_sites = []
        @parse_errors = []
      end

      def build
        @call_sites = []
        @parse_errors = []

        @files.each do |path|
          extract_from_file(path)
        end

        self
      end

      private

      def extract_from_file(path)
        content = File.read(path)
        result = Prism.parse(content)

        if result.errors.any?
          result.errors.each do |err|
            @parse_errors << { path: path, message: err.message, line: err.location&.start_line }
          end
          return
        end

        extract_nodes(path, result.value, [])
      rescue StandardError => e
        @parse_errors << { path: path, message: e.message, line: nil }
      end

      def extract_nodes(path, node, enclosing_methods)
        return unless node

        # Track enclosing method context
        enclosing_methods += [node.name.to_s] if node.is_a?(Prism::DefNode)

        # Extract call nodes
        case node
        when Prism::CallNode
          extract_call_site(path, node, enclosing_methods)
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          # Track constant references if needed
        end

        # Recurse into child nodes
        child_nodes(node).each do |child|
          extract_nodes(path, child, enclosing_methods)
        end
      end

      def extract_call_site(path, node, enclosing_methods)
        receiver = node.receiver
        method_name = node.name
        location = node.location

        # Extract receiver source text
        receiver_source = if receiver
                            source_range = receiver.location
                            File.read(path)[source_range.start_offset...source_range.end_offset]
                          end

        # Extract enclosing symbol
        enclosing_symbol = if enclosing_methods.any?
                             # Build symbol like "ClassName#method_name" or "ClassName.method_name"
                             # For simplicity, use the most recent method
                             enclosing_methods.last.to_s
                           end

        @call_sites << {
          path: path,
          line: location.start_line,
          column: location.start_column,
          receiver_source: receiver_source,
          method_name: method_name.to_s,
          enclosing_symbol: enclosing_symbol,
          nesting: [], # Will be filled by context resolver
          receiver_constant: nil, # Will be resolved by SemanticIndex
          confidence: receiver_source ? :low : :unknown
        }
      end

      def child_nodes(node)
        nodes = []
        node.child_nodes.each do |child|
          nodes << child if child
        end
        nodes
      rescue NoMethodError
        []
      end
    end
  end
end
