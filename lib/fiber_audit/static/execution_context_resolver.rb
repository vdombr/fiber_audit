# frozen_string_literal: true

require_relative '../execution_context'

module FiberAudit
  module Static
    # Resolves execution context for call sites based on semantic ancestry,
    # path heuristics, and callback DSL patterns.
    #
    # Resolution priority:
    # 1. Semantic inheritance (outranks path)
    # 2. Path-based fallback
    # 3. Callback DSL sniff
    # 4. :unknown
    #
    # Never raises; always returns a Context symbol.
    class ExecutionContextResolver
      # Semantic ancestry signals mapped to contexts
      SEMANTIC_SIGNALS = {
        'ActionController::Base' => Context::REQUEST,
        'ActionController::API' => Context::REQUEST,
        'ActionJob::Base' => Context::JOB, # typo tolerance
        'ActiveJob::Base' => Context::JOB,
        'ActionCable::Channel::Base' => Context::WEBSOCKET,
        'ActionView::Base' => Context::VIEW
      }.freeze

      # Callback model ancestors (ActiveRecord/model ancestry only)
      CALLBACK_ANCESTORS = %w[
        ActiveRecord::Base
      ].freeze

      # @param workspace [Object] responds to ancestors_of(name) OR exposes semantic_index
      def initialize(workspace:)
        @workspace = workspace
      end

      # Resolve context for a single call site
      # @param call_site [CallSite] a call site with path, enclosing_symbol, nesting
      # @return [Symbol] one of Context::ALL
      def resolve(call_site:)
        path = call_site.path
        enclosing = call_site.enclosing_symbol
        nesting = Array(call_site.nesting)

        # Try semantic inheritance first (outranks path)
        semantic = resolve_from_semantics(enclosing, nesting)
        return semantic if semantic

        # Path-based fallback
        path_ctx = resolve_from_path(path, enclosing)
        return path_ctx if path_ctx

        # Callback DSL sniff
        callback_ctx = resolve_callback(enclosing, nesting)
        return callback_ctx if callback_ctx

        Context::UNKNOWN
      rescue StandardError
        Context::UNKNOWN
      end

      # Resolve contexts for all call sites, returning new CallSite objects
      # with execution_context populated. Does not mutate originals.
      #
      # @param call_sites [Array<CallSite>]
      # @return [Array<CallSite>] new array in original order
      # Never silently returns an unchanged object when copying fails—
      # unknown is still populated where compatible.
      def resolve_all(call_sites:)
        Array(call_sites).map do |cs|
          ctx = resolve(call_site: cs)
          copy_with_context(cs, ctx)
        end
      rescue StandardError
        # If batch fails, try individually with :unknown.
        # If copy itself fails (not a Data type), let it propagate—
        # never silently return an unchanged object.
        Array(call_sites).map do |cs|
          copy_with_context(cs, Context::UNKNOWN)
        end
      end

      private

      # Extract enclosing class name from enclosing_symbol
      # "ClassName#method" or "ClassName.method" → "ClassName"
      # "Namespace::Class#method" → "Namespace::Class"
      def extract_class(enclosing_symbol)
        return nil if enclosing_symbol.nil? || enclosing_symbol.empty?

        # Split on # or . and take the class part
        if enclosing_symbol.include?('#')
          enclosing_symbol.split('#', 2).first
        elsif enclosing_symbol.include?('.')
          enclosing_symbol.split('.', 2).first
        end
      end

      # Extract method name from enclosing_symbol
      # "ClassName#method" → "method"
      # "ClassName.method" → "method"
      def extract_method(enclosing_symbol)
        return nil if enclosing_symbol.nil? || enclosing_symbol.empty?

        if enclosing_symbol.include?('#')
          enclosing_symbol.split('#', 2).last
        elsif enclosing_symbol.include?('.')
          enclosing_symbol.split('.', 2).last
        end
      end

      # Try to resolve from semantic ancestry with transitive traversal
      def resolve_from_semantics(enclosing_symbol, nesting)
        # Try enclosing class first
        klass = extract_class(enclosing_symbol)
        if klass
          result = check_semantic_ancestors_transitive(klass)
          return result if result
        end

        # Try nesting (innermost first)
        nesting.reverse_each do |name|
          result = check_semantic_ancestors_transitive(name)
          return result if result
        end

        nil
      end

      # Check class name and its transitive ancestors with cycle detection
      # @param class_name [String] the class name to check
      # @param visited [Set] set of already-visited class names (for cycle detection)
      # @return [Symbol, nil] the context if found, nil otherwise
      def check_semantic_ancestors_transitive(class_name, visited = Set.new)
        return nil unless class_name
        return nil if visited.include?(class_name)

        visited.add(class_name)

        # Match the class itself first (known class signal, even if ancestors empty)
        signal = SEMANTIC_SIGNALS[class_name]
        return signal if signal

        # Get ancestors
        ancestors = safe_ancestors_of(class_name)
        return nil if ancestors.empty?

        # Check each ancestor and recurse transitively
        ancestors.each do |ancestor_name|
          # Check if this ancestor is a known signal
          ancestor_signal = SEMANTIC_SIGNALS[ancestor_name]
          return ancestor_signal if ancestor_signal

          # Recurse transitively with cycle detection
          result = check_semantic_ancestors_transitive(ancestor_name, visited)
          return result if result
        end

        nil
      end

      # Resolve from path segments with contiguous boundary-safe sequences
      def resolve_from_path(path, enclosing_symbol)
        return nil unless path

        # Normalize Windows backslashes to forward slashes
        normalized = path.tr('\\', '/')
        segments = normalized.split('/')

        # Contiguous boundary-safe sequences
        # config/initializers → boot
        return Context::BOOT if contiguous_pair?(segments, 'config', 'initializers')

        # lib/tasks → rake_task
        return Context::RAKE_TASK if contiguous_pair?(segments, 'lib', 'tasks')

        # basename Rakefile → rake_task
        return Context::RAKE_TASK if File.basename(normalized) == 'Rakefile'

        # app/views → view
        return Context::VIEW if contiguous_pair?(segments, 'app', 'views')

        # spec or test segment → test (exact segment match, not substring)
        return Context::TEST if segments.include?('spec') || segments.include?('test')

        # config.ru requires enclosing instance #call specifically
        # Must be instance method (#call), not class method (.call)
        # Must be exactly 'call', not a substring like 'callback'
        if File.basename(normalized) == 'config.ru'
          method = extract_method(enclosing_symbol)
          return Context::MIDDLEWARE if enclosing_symbol&.include?('#') && method == 'call'
        end

        nil
      end

      # Check if two segments appear contiguously in the path
      # @param segments [Array<String>] path segments
      # @param first [String] first segment
      # @param second [String] second segment
      # @return [Boolean] true when first is immediately followed by second
      def contiguous_pair?(segments, first, second)
        segments.each_cons(2).any? do |left, right|
          left == first && right == second
        end
      end

      # Resolve callback DSL
      def resolve_callback(enclosing_symbol, nesting)
        method = extract_method(enclosing_symbol)
        return nil unless method

        # Method starts with before_/after_/around_
        return nil unless method.start_with?('before_', 'after_', 'around_')

        # Check if any enclosing class has ActiveRecord/model ancestry
        klass = extract_class(enclosing_symbol)
        candidate_classes = [klass, *nesting].compact

        candidate_classes.each do |name|
          ancestors = safe_ancestors_of(name)
          return Context::CALLBACK if ancestors.any? { |a| CALLBACK_ANCESTORS.include?(a) }
        end

        nil
      end

      # Get ancestors from workspace safely, never raises
      # Tries workspace.ancestors_of or workspace.semantic_index.ancestors_of
      def safe_ancestors_of(name)
        return [] unless name

        # Try workspace.ancestors_of directly
        if @workspace.respond_to?(:ancestors_of)
          @workspace.ancestors_of(name)
        # Try workspace.semantic_index.ancestors_of
        elsif @workspace.respond_to?(:semantic_index) &&
              @workspace.semantic_index.respond_to?(:ancestors_of)
          @workspace.semantic_index.ancestors_of(name)
        else
          []
        end
      rescue StandardError
        []
      end

      # Create a new CallSite with execution_context populated
      # Does not mutate the original
      # Never silently returns the unchanged object
      def copy_with_context(call_site, context)
        klass = call_site.class
        unless klass.respond_to?(:members)
          # Cannot copy immutably - raise instead of silently returning unchanged
          raise TypeError, "Cannot immutably copy #{klass}: not a Data type"
        end

        attrs = {}
        klass.members.each { |m| attrs[m] = call_site.send(m) }
        attrs[:execution_context] = context
        klass.new(**attrs)
      end
    end
  end
end
