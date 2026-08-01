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
        'ActionJob::Base' => Context::JOB,  # typo tolerance
        'ActiveJob::Base' => Context::JOB,
        'ActionCable::Channel::Base' => Context::WEBSOCKET,
        'ActionView::Base' => Context::VIEW
      }.freeze

      # Callback model-ish ancestors
      CALLBACK_ANCESTORS = %w[
        ActiveRecord::Base
        ActiveSupport::Concern
        ActiveRecord::Callbacks
      ].freeze

      # @param workspace [Object] responds to ancestors_of(name) OR exposes semantic_index
      def initialize(workspace:)
        @workspace = workspace
      end

      # Resolve context for a single call site
      # @param call_site [CallSite] a call site with path, enclosing_symbol, nesting
      # @return [Symbol] one of Context::ALL
      def resolve(call_site)
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
      def resolve_all(call_sites)
        Array(call_sites).map do |cs|
          ctx = resolve(cs)
          copy_with_context(cs, ctx)
        end
      rescue StandardError
        Array(call_sites).map { |cs| copy_with_context(cs, Context::UNKNOWN) }
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
        else
          nil
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
        else
          nil
        end
      end

      # Try to resolve from semantic ancestry
      def resolve_from_semantics(enclosing_symbol, nesting)
        # Try enclosing class first
        klass = extract_class(enclosing_symbol)
        if klass
          result = check_semantic_ancestors(klass)
          return result if result
        end

        # Try nesting (innermost first)
        nesting.reverse_each do |name|
          result = check_semantic_ancestors(name)
          return result if result
        end

        nil
      end

      # Check if a class name has known semantic ancestors
      def check_semantic_ancestors(class_name)
        return nil unless class_name

        ancestors = ancestors_of(class_name)
        return nil if ancestors.empty?

        # Check direct class name match
        SEMANTIC_SIGNALS.each do |signal, ctx|
          return ctx if ancestors.include?(signal) || class_name == signal
        end

        nil
      end

      # Resolve from path segments
      def resolve_from_path(path, enclosing_symbol)
        return nil unless path

        segments = split_path(path)

        # config/initializers → boot
        return Context::BOOT if segments.include?('config') && segments.include?('initializers')

        # lib/tasks or basename Rakefile → rake_task
        return Context::RAKE_TASK if segments.include?('tasks') && segments.include?('lib')
        return Context::RAKE_TASK if File.basename(path) == 'Rakefile'

        # app/views → view
        return Context::VIEW if segments.include?('app') && segments.include?('views')

        # spec or test segment → test
        return Context::TEST if segments.include?('spec') || segments.include?('test')

        # config.ru with enclosing #call → middleware
        return Context::MIDDLEWARE if File.basename(path) == 'config.ru' &&
                                      enclosing_symbol&.include?('#call')

        nil
      end

      # Resolve callback DSL
      def resolve_callback(enclosing_symbol, nesting)
        method = extract_method(enclosing_symbol)
        return nil unless method

        # Method starts with before_/after_/around_
        return nil unless method.start_with?('before_', 'after_', 'around_')

        # Check if any enclosing class has model-ish ancestry
        klass = extract_class(enclosing_symbol)
        candidate_classes = [klass, *nesting].compact

        candidate_classes.each do |name|
          ancestors = ancestors_of(name)
          return Context::CALLBACK if ancestors.any? { |a| CALLBACK_ANCESTORS.include?(a) }
        end

        nil
      end

      # Get ancestors from workspace
      def ancestors_of(name)
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

      # Split path into segments safely
      def split_path(path)
        path.to_s.split('/')
      end

      # Create a new CallSite with execution_context populated
      # Does not mutate the original
      def copy_with_context(call_site, context)
        if call_site.class.respond_to?(:members)
          # Data.define style
          attrs = call_site.class.members.map { |m| [m, call_site.send(m)] }.to_h
          attrs[:execution_context] = context
          call_site.class.new(**attrs)
        else
          # Fallback: try to copy manually
          call_site
        end
      rescue StandardError
        call_site
      end
    end
  end
end
