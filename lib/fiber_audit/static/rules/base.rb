# frozen_string_literal: true

require_relative '../../findings/severity'
require_relative '../../findings/confidence'

module FiberAudit
  module Static
    module Rules
      # Base class for all static analysis rules.
      #
      # Subclasses use the class-level DSL to declare metadata:
      #
      #   class BlockingSubprocess < Base
      #     id 'FA1001'
      #     severity :high
      #     confidence :high
      #     description 'Blocking subprocess call in the fiber scheduler path'
      #
      #     def analyze(call_sites:)
      #       # ...
      #     end
      #   end
      #
      # Severity resolution flow (monotonic):
      #   1. Start with the rule's default_severity
      #   2. Apply configuration.severity_override (replaces default if present)
      #   3. Apply context ceiling: if the resulting severity is less severe
      #      than the ceiling for the execution context, raise to the ceiling.
      #      Never lower a severity that is already more severe than the ceiling.
      #
      class Base
        # Context severity ceiling table.
        #
        # For each execution context, the ceiling is the minimum severity
        # (maximum urgency) that a finding must reach. If the rule's base
        # severity is already at or above the ceiling, it is left unchanged.
        # A nil ceiling (unknown context) means no upgrade is applied.
        #
        CONTEXT_CEILING = {
          request: :critical,
          middleware: :critical,
          websocket: :critical,
          callback: :high,
          view: :high,
          job: :high,
          boot: :medium,
          console: :info,
          test: :info,
          rake_task: :low,
          unknown: nil
        }.freeze

        class << self
          # Get or set the rule identifier.
          # Coerces the value to a frozen String.
          def id(value = nil)
            return @rule_id unless value

            @rule_id = value.to_s.freeze
          end

          # Get or set the default severity.
          # When setting, validates via Severity.coerce.
          # Accepts Symbol or String values; Strings are normalized to Symbols.
          def severity(value = nil)
            return @default_severity unless value

            normalized = value.is_a?(String) ? value.to_sym : value
            @default_severity = Severity.coerce(normalized)
          end

          # Alias: getter for the default severity.
          # Also accepts a value for DSL symmetry (delegates to severity).
          def default_severity(value = nil)
            return @default_severity unless value

            severity(value)
          end

          # Get or set the default confidence.
          # When setting, validates via Confidence.coerce.
          # Accepts Symbol or String values; Strings are normalized to Symbols.
          def confidence(value = nil)
            return @default_confidence unless value

            normalized = value.is_a?(String) ? value.to_sym : value
            @default_confidence = Confidence.coerce(normalized)
          end

          # Alias: getter for the default confidence.
          # Also accepts a value for DSL symmetry (delegates to confidence).
          def default_confidence(value = nil)
            return @default_confidence unless value

            confidence(value)
          end

          # Get or set the human-readable description.
          def description(value = nil)
            return @description unless value

            @description = value.to_s.freeze
          end
        end

        # Construct a rule instance with its dependencies.
        #
        # @param workspace [Object] the analysis workspace
        # @param context_resolver [Object] resolves call-site execution contexts
        # @param configuration [FiberAudit::Configuration] audit configuration
        def initialize(workspace:, context_resolver:, configuration:)
          @workspace = workspace
          @context_resolver = context_resolver
          @configuration = configuration
        end

        # Analyze call sites and return an array of findings.
        # Subclasses MUST override this method.
        #
        # @param call_sites [Array<FiberAudit::Static::CallSite>]
        # @return [Array<FiberAudit::Finding>]
        # @raise [NotImplementedError]
        def analyze(call_sites:)
          raise NotImplementedError,
                "#{self.class.name}#analyze must be implemented by the subclass"
        end

        protected

        # @return [Object] the analysis workspace
        attr_reader :workspace

        # @return [Object] the execution-context resolver
        attr_reader :context_resolver

        # @return [FiberAudit::Configuration] the audit configuration
        attr_reader :configuration

        private

        # Compute the final severity for a finding.
        #
        # Resolution order:
        #   1. configuration.severity_override(rule_id) replaces the default
        #   2. Context ceiling monotonically raises (never lowers)
        #
        # @param default_sev [Symbol, String] rule's default severity
        # @param context [Symbol, nil] execution context (nil → :unknown)
        # @return [Symbol] the resolved severity
        def severity_for(default_sev, context)
          # Normalize String to Symbol defensively
          default_sev = default_sev.to_sym if default_sev.is_a?(String)

          # Step 1: configuration override (replaces default entirely)
          base = configuration.severity_override(self.class.id) || default_sev

          # Step 2: context ceiling (monotonic raise only)
          ctx = context || :unknown
          ceiling = CONTEXT_CEILING.fetch(ctx) do
            CONTEXT_CEILING[:unknown]
          end

          return base if ceiling.nil?

          # If the base severity is less severe than the ceiling (higher index),
          # raise it to the ceiling. Otherwise keep it (never lower).
          if Severity.index(base) > Severity.index(ceiling)
            ceiling
          else
            base
          end
        end

        # Severity index helper — delegates to Severity.index.
        # Lower index = more severe (0 = :critical, 4 = :info).
        #
        # @param severity [Symbol] a severity level
        # @return [Integer] the numeric index
        def severity_index(severity)
          Severity.index(severity)
        end

        # Compute the advisory severity for a finding without applying
        # the context ceiling. Advisory rules (FA1002, FA1003, FA1005,
        # FA1006, FA1007) use this to respect configuration overrides
        # but not escalate based on execution context.
        #
        # Resolution order:
        #   1. configuration.severity_override(rule_id) replaces the default
        #   2. No context ceiling is applied
        #
        # @param default_sev [Symbol, String] rule's default severity
        # @return [Symbol] the resolved severity
        def advisory_severity(default_sev)
          # Normalize String to Symbol defensively
          default_sev = default_sev.to_sym if default_sev.is_a?(String)

          # Configuration override replaces default entirely, no ceiling
          configuration.severity_override(self.class.id) || default_sev
        end
      end
    end
  end
end
