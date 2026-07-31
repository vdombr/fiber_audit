# frozen_string_literal: true

require 'pathname'
require 'rubydex'

module FiberAudit
  module Static
    class SemanticIndex
      Declaration = Data.define(:name, :kind, :path, :line)
      Reference = Data.define(:name, :path, :line, :column, :context)
      Constant = Data.define(:name, :path, :line)
      RubydexGap = Data.define(:method, :reason)

      attr_reader :root, :gaps

      def initialize(root:)
        @root = Pathname.new(root).expand_path
        @graph = nil
        @gaps = []
      end

      def build
        @graph = ::Rubydex::Graph.new
        @graph.workspace_path = @root.to_s
        @graph.index_workspace
        @graph.resolve
        record_gaps
        self
      end

      # Returns Array[Declaration] for classes/modules/methods in the workspace
      def declarations
        return [] unless @graph

        @graph.declarations.select { |d| workspace_declaration?(d) }.map do |decl|
          loc = first_location(decl)
          next unless loc

          kind = declaration_kind(decl)
          Declaration.new(name: decl.name, kind: kind, path: loc.to_file_path, line: loc.start_line)
        end.compact
      end

      # Resolves a constant name to a Constant object
      def resolve_constant(name, nesting:)
        return nil unless @graph

        result = @graph.resolve_constant(name.to_s, nesting || [])
        return nil unless result

        loc = first_location(result)
        return nil unless loc

        Constant.new(name: result.name, path: loc.to_file_path, line: loc.start_line)
      rescue ::Rubydex::Location::NotFileUriError
        nil
      end

      # Returns Array[String] of ancestor class/module names
      def ancestors_of(name)
        return [] unless @graph

        decl = find_declaration(name)
        return [] unless decl
        return [] unless decl.respond_to?(:has_ancestor?)

        # Rubydex doesn't expose a direct "list all ancestors" method
        # We use has_ancestor? to check known ancestors from declarations
        @graph.declarations
              .select { |d| workspace_declaration?(d) && class_or_module?(d) }
              .map(&:name)
              .select { |ancestor_name| decl.has_ancestor?(ancestor_name) && ancestor_name != name }
      end

      # Returns Array[String] of descendant class/module names
      def descendants_of(name)
        return [] unless @graph

        decl = find_declaration(name)
        return [] unless decl
        return [] unless decl.respond_to?(:descendants)

        decl.descendants.map(&:name).uniq - [name]
      end

      # Returns Array[Reference] for references to a given constant
      def references_to(name)
        return [] unless @graph

        @graph.constant_references.select { |r| r.respond_to?(:declaration) && r.declaration&.name == name }.map do |ref|
          loc = ref.location
          path = loc.to_file_path
          next unless path.start_with?(@root.to_s)

          {
            name: name,
            path: path,
            line: loc.start_line,
            column: loc.start_column,
            context: nil
          }
        rescue ::Rubydex::Location::NotFileUriError
          nil
        end.compact
      end

      private

      def workspace_declaration?(decl)
        return false unless decl.respond_to?(:definitions)

        decl.definitions.any? do |defn|
          path = defn.location.to_file_path
          path.start_with?(@root.to_s)
        rescue ::Rubydex::Location::NotFileUriError
          false
        end
      end

      def first_location(decl)
        return nil unless decl.respond_to?(:definitions)

        defn = decl.definitions.first
        return nil unless defn

        defn.location
      rescue ::Rubydex::Location::NotFileUriError
        nil
      end

      def declaration_kind(decl)
        case decl
        when ::Rubydex::Class then :class
        when ::Rubydex::Module then :module
        when ::Rubydex::Method then :method
        else :unknown
        end
      end

      def class_or_module?(decl)
        decl.is_a?(::Rubydex::Class) || decl.is_a?(::Rubydex::Module)
      end

      def find_declaration(name)
        @graph.declarations.find do |d|
          workspace_declaration?(d) && d.name == name.to_s
        end
      end

      def record_gaps
        return if @gaps.any?

        @gaps << {
          method: 'method_name_from_reference',
          reason: 'Rubydex::MethodReference only exposes receiver and location, not the method name being called'
        }
        @gaps << {
          method: 'ancestors_list',
          reason: 'Rubydex only provides has_ancestor?(name) for checking individual ancestors, not a full ancestor chain'
        }
        @gaps << {
          method: 'call_site_extraction',
          reason: 'Rubydex tracks method references but without method names or full call context; Prism AST parsing needed'
        }
      end
    end
  end
end
