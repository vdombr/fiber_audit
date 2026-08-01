# frozen_string_literal: true

require_relative 'base'

module FiberAudit
  module Static
    module Rules
      # Registry for managing rule classes.
      #
      # The registry holds rule classes (not instances) and can instantiate them
      # with the appropriate dependencies for a given configuration.
      #
      # Usage:
      #   registry = Registry.new(workspace: ws, context_resolver: resolver)
      #   registry.register(BlockingSubprocess)
      #   registry.register(ThreadJoin)
      #
      #   # Find a rule class by ID
      #   rule_class = registry['FA1001']
      #
      #   # Get all enabled rule instances for a configuration
      #   instances = registry.enabled_for(configuration)
      #   instances.each do |rule|
      #     findings = rule.analyze(call_sites: call_sites)
      #   end
      #
      class Registry
        include Enumerable

        # @param workspace [Object, nil] the analysis workspace
        # @param context_resolver [Object, nil] resolves execution contexts
        def initialize(workspace: nil, context_resolver: nil)
          @workspace = workspace
          @context_resolver = context_resolver
          @rules = []
        end

        # Register a rule class.
        #
        # @param rule_class [Class] must be a subclass of Base with an id set
        # @return [self] for chaining
        # @raise [ArgumentError] if rule_class is not a Base subclass, has no id, or id is duplicate
        def register(rule_class)
          validate_rule_class!(rule_class)

          rule_id = rule_class.id
          if @rules.any? { |r| r.id == rule_id }
            raise ArgumentError,
                  "Rule with id '#{rule_id}' is already registered"
          end

          @rules << rule_class
          self
        end

        # Find a rule class by ID (string or symbol).
        #
        # @param id [String, Symbol] the rule identifier
        # @return [Class, nil] the rule class, or nil if not found
        def [](id)
          id_str = id.to_s
          @rules.find { |r| r.id == id_str }
        end

        # Alias for []
        alias find []

        # Return all registered rule classes in insertion order.
        #
        # @return [Array<Class>] array of rule classes
        def list
          @rules.dup
        end

        # Iterate over registered rule classes.
        #
        # @yieldparam rule_class [Class] each registered rule class
        # @return [Enumerator] if no block given
        def each(&block)
          @rules.each(&block)
        end

        # Instantiate all enabled rules for the given configuration.
        #
        # Filters rules by configuration.rule_enabled?(id) and returns instances
        # initialized with the registry's workspace, context_resolver, and the
        # provided configuration.
        #
        # @param configuration [FiberAudit::Configuration] audit configuration
        # @return [Array<Base>] array of instantiated rule objects
        def enabled_for(configuration)
          @rules.select do |rule_class|
            configuration.rule_enabled?(rule_class.id)
          end.map do |rule_class|
            rule_class.new(
              workspace: @workspace,
              context_resolver: @context_resolver,
              configuration: configuration
            )
          end
        end

        private

        # Validate that a rule class meets the requirements for registration.
        #
        # @param rule_class [Class] the class to validate
        # @raise [ArgumentError] if validation fails
        def validate_rule_class!(rule_class)
          unless rule_class.is_a?(Class) && rule_class < Base
            raise ArgumentError,
                  "rule_class must be a subclass of Base, got #{rule_class.inspect}"
          end

          if rule_class.id.nil? || rule_class.id.empty?
            raise ArgumentError,
                  'rule_class must have an id set via the DSL'
          end
        end
      end
    end
  end
end
