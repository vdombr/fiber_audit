# frozen_string_literal: true

require 'pathname'
require 'rubydex'

module FiberAudit
  module Static
    # Semantic index backed by Rubydex 0.2.9.
    #
    # === Line/column conventions (FiberAudit standard)
    # * Lines are **one-based** (1, 2, 3, ...).
    # * Columns are **zero-based** (0, 1, 2, ...).
    #
    # Rubydex 0.2.9 reports start_line as **zero-based** and start_column as
    # zero-based. The +normalize_location+ helper adds 1 to start_line so that
    # all returned locations use FiberAudit's one-based line convention.
    class SemanticIndex
      # Data types returned by public seams.
      Declaration = Data.define(:name, :kind, :path, :line)
      Reference   = Data.define(:name, :path, :line, :column, :context)
      Constant    = Data.define(:name, :path, :line)
      RubydexGap  = Data.define(:method, :reason)

      attr_reader :root, :gaps

      def initialize(root:)
        @root = Pathname.new(root).expand_path.cleanpath
        @graph = nil
        @gaps = []
      end

      # Build (or rebuild) the index. Clears and deduplicates gaps on every call.
      def build
        @gaps = []
        @graph = ::Rubydex::Graph.new
        @graph.workspace_path = @root.to_s
        @graph.index_workspace
        @graph.resolve
        record_gaps
        self
      rescue StandardError => e
        @gaps << RubydexGap.new(method: 'build', reason: e.message)
        self
      end

      # Returns Array[Declaration] for classes/modules/methods in the workspace.
      # Returns one Declaration per workspace definition site so that reopened
      # classes expose both (or more) definition sites.
      def declarations
        return [] unless @graph

        @graph.declarations.select { |d| workspace_declaration?(d) }.filter_map do |decl|
          kind = declaration_kind(decl)
          workspace_definition_locations(decl).filter_map do |loc|
            path, line = normalize_location(loc)
            next unless path

            Declaration.new(name: decl.name, kind: kind, path: path, line: line)
          end
        end.flatten
      rescue StandardError
        []
      end

      # Resolves a constant name to a Constant object.
      # Returns nil if the constant cannot be resolved or is outside the workspace.
      def resolve_constant(name, nesting:)
        return nil unless @graph

        result = @graph.resolve_constant(name.to_s, nesting || [])
        return nil unless result

        loc = first_workspace_location(result)
        return nil unless loc

        path, line = normalize_location(loc)
        Constant.new(name: result.name, path: path, line: line)
      rescue StandardError
        nil
      end

      # Returns Array[String] of ancestor class/module names.
      # Uses Rubydex's +ancestors+ method which considers ALL class/module
      # declarations (including external/framework ancestors) while the target
      # declaration itself remains workspace-owned (via find_declaration).
      def ancestors_of(name)
        return [] unless @graph

        decl = find_declaration(name)
        return [] unless decl
        return [] unless decl.respond_to?(:ancestors)

        ancestors = decl.ancestors
        return [] unless ancestors

        ancestors.select { |ancestor| class_or_module?(ancestor) && ancestor.name != name }
                 .map(&:name)
      rescue StandardError
        []
      end

      # Returns Array[String] of descendant class/module names.
      # Gracefully returns [] if Rubydex cannot compute descendants.
      def descendants_of(name)
        return [] unless @graph

        decl = find_declaration(name)
        return [] unless decl
        return [] unless decl.respond_to?(:descendants)

        descendants = decl.descendants
        return [] unless descendants

        descendants.map(&:name).uniq - [name]
      rescue StandardError
        []
      end

      # Returns Array[Reference] for references to a given constant.
      # Filters to workspace and rescues non-file URIs per reference.
      def references_to(name)
        return [] unless @graph

        @graph.constant_references.filter_map do |ref|
          next unless ref.respond_to?(:declaration) && ref.declaration&.name == name

          loc = ref.location
          next unless workspace_location?(loc)

          path, line, column = normalize_location_full(loc)
          Reference.new(name: name, path: path, line: line, column: column, context: nil)
        rescue StandardError
          nil
        end
      rescue StandardError
        []
      end

      private

      # ---- Pathname-based workspace containment ----

      # Check if a file path is within the workspace using Pathname ancestry.
      # This avoids string-prefix false positives like /workspace matching /workspace-other.
      def workspace_path?(file_path)
        return false unless file_path && !file_path.empty?

        path_obj = Pathname.new(file_path)
        path_obj == @root || path_obj.ascend.any? { |ancestor| ancestor == @root }
      rescue ArgumentError, TypeError
        false
      end

      # Check if a Rubydex location points to a file within the workspace.
      # Rescues non-file URIs (e.g. gem:// URIs) per location.
      def workspace_location?(loc)
        return false unless loc

        file_path = location_file_path(loc)
        return false unless file_path

        workspace_path?(file_path)
      rescue StandardError
        false
      end

      def workspace_declaration?(decl)
        return false unless decl.respond_to?(:definitions)

        decl.definitions.any? do |defn|
          workspace_location?(defn.location)
        rescue StandardError
          false
        end
      rescue StandardError
        false
      end

      # ---- Definition site enumeration ----

      # Returns all workspace-owned locations from a declaration's definitions.
      # This ensures reopened classes expose all definition sites.
      def workspace_definition_locations(decl)
        return [] unless decl.respond_to?(:definitions)

        decl.definitions.filter_map do |d|
          d.location if workspace_location?(d.location)
        rescue StandardError
          nil
        end
      rescue StandardError
        []
      end

      # Returns the first workspace-owned location from a declaration's definitions.
      # Used for constant resolution where only the primary site is needed.
      def first_workspace_location(decl)
        return nil unless decl.respond_to?(:definitions)

        defn = decl.definitions.find do |d|
          workspace_location?(d.location)
        rescue StandardError
          false
        end
        defn&.location
      rescue StandardError
        nil
      end

      # ---- Location normalization (FiberAudit: 1-based lines, 0-based columns) ----

      # Extracts the file system path from a rubydex location.
      # Uses to_file_path which raises NotFileUriError for non-file URIs.
      def location_file_path(loc)
        loc.to_file_path
      rescue ::Rubydex::Location::NotFileUriError
        nil
      rescue StandardError
        nil
      end

      # Normalize a rubydex location to [path, line] for Declaration/Constant.
      # Rubydex 0.2.9 reports start_line as zero-based; we add 1 for the
      # FiberAudit one-based line convention.
      def normalize_location(loc)
        path = location_file_path(loc)
        [path, loc.start_line + 1]
      rescue StandardError
        [nil, nil]
      end

      # Normalize a rubydex location to [path, line, column] for Reference.
      # Rubydex 0.2.9 reports start_line as zero-based; we add 1 for the
      # FiberAudit one-based line convention. Columns remain zero-based.
      def normalize_location_full(loc)
        path = location_file_path(loc)
        [path, loc.start_line + 1, loc.start_column]
      rescue StandardError
        [nil, nil, nil]
      end

      def declaration_kind(decl)
        case decl
        when defined?(::Rubydex::Class) && ::Rubydex::Class
          :class
        when defined?(::Rubydex::Module) && ::Rubydex::Module
          :module
        when defined?(::Rubydex::Method) && ::Rubydex::Method
          :method
        else
          :unknown
        end
      end

      def class_or_module?(decl)
        return false unless decl

        (defined?(::Rubydex::Class) && decl.is_a?(::Rubydex::Class)) ||
          (defined?(::Rubydex::Module) && decl.is_a?(::Rubydex::Module))
      end

      def find_declaration(name)
        @graph.declarations.find do |d|
          workspace_declaration?(d) && d.name == name.to_s
        end
      rescue StandardError
        nil
      end

      # ---- Gap management ----

      # Clears and deduplicates gaps on each build.
      # Uses RubydexGap Data objects (not hashes).
      def record_gaps
        known_gaps = [
          RubydexGap.new(
            method: 'method_name_from_reference',
            reason: 'Rubydex::MethodReference only exposes receiver and location, not the method name being called'
          ),
          RubydexGap.new(
            method: 'ancestors_external',
            reason: 'Rubydex ancestors may not include all external/framework ancestors without explicit indexing of those dependencies'
          ),
          RubydexGap.new(
            method: 'call_site_extraction',
            reason: 'Rubydex tracks method references but without method names or full call context; Prism AST parsing needed'
          ),
          RubydexGap.new(
            method: 'dynamic_methods',
            reason: 'Rubydex may not fully track methods defined via define_method, method_missing, or other metaprogramming'
          ),
          RubydexGap.new(
            method: 'def_delegator_tracking',
            reason: 'Forwardable def_delegator creates method aliases that Rubydex may not fully resolve to their target'
          )
        ]

        @gaps = (known_gaps + @gaps).uniq
      end
    end
  end
end
