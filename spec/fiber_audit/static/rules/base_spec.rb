# frozen_string_literal: true

# Test rules preserve the production keyword API even when their inputs are
# irrelevant, and table constants are scoped to this example group.
# rubocop:disable Lint/UnusedMethodArgument, Lint/ConstantDefinitionInBlock

require 'fiber_audit/static/rules/base'
require 'fiber_audit/configuration'

RSpec.describe FiberAudit::Static::Rules::Base do
  # ── Test subclass ────────────────────────────────────────────────────
  let(:test_rule_class) do
    Class.new(described_class) do
      id 'FA9999'
      severity :high
      confidence :high
      description 'Test rule for spec coverage'

      def analyze(call_sites:)
        # Return empty; real rules produce findings
        []
      end
    end
  end

  let(:workspace)          { double('workspace') }
  let(:context_resolver)   { double('context_resolver') }
  let(:configuration)      do
    instance_double(FiberAudit::Configuration,
                    severity_override: nil,
                    rule_enabled?: true)
  end

  let(:instance) do
    test_rule_class.new(
      workspace: workspace,
      context_resolver: context_resolver,
      configuration: configuration
    )
  end

  # ── Metadata DSL ─────────────────────────────────────────────────────
  describe 'metadata DSL' do
    it 'sets and returns the rule id' do
      expect(test_rule_class.id).to eq('FA9999')
    end

    it 'coerces id to a frozen String' do
      klass = Class.new(described_class) { id :FA1234 }
      expect(klass.id).to eq('FA1234')
      expect(klass.id).to be_frozen
    end

    it 'sets and returns the default severity via severity DSL' do
      expect(test_rule_class.severity).to eq(:high)
    end

    it 'sets and returns the default severity via default_severity DSL' do
      expect(test_rule_class.default_severity).to eq(:high)
    end

    it 'coerces severity on set' do
      klass = Class.new(described_class) { severity 'medium' }
      expect(klass.severity).to eq(:medium)
    end

    it 'normalizes String severity to Symbol before coercion' do
      klass = Class.new(described_class) { severity 'high' }
      expect(klass.severity).to eq(:high)
      expect(klass.severity).to be_a(Symbol)
    end

    it 'raises ArgumentError for invalid severity' do
      expect do
        Class.new(described_class) { severity :extreme }
      end.to raise_error(ArgumentError, /unknown severity/)
    end

    it 'sets and returns the default confidence via confidence DSL' do
      expect(test_rule_class.confidence).to eq(:high)
    end

    it 'sets and returns the default confidence via default_confidence DSL' do
      expect(test_rule_class.default_confidence).to eq(:high)
    end

    it 'raises ArgumentError for invalid confidence' do
      expect do
        Class.new(described_class) { confidence :definite }
      end.to raise_error(ArgumentError, /unknown confidence/)
    end

    it 'coerces confidence on set' do
      klass = Class.new(described_class) { confidence 'medium' }
      expect(klass.confidence).to eq(:medium)
    end

    it 'normalizes String confidence to Symbol before coercion' do
      klass = Class.new(described_class) { confidence 'high' }
      expect(klass.confidence).to eq(:high)
      expect(klass.confidence).to be_a(Symbol)
    end

    it 'sets and returns the description' do
      expect(test_rule_class.description).to eq('Test rule for spec coverage')
    end

    it 'freezes the description' do
      expect(test_rule_class.description).to be_frozen
    end

    it 'isolates metadata per subclass (no cross-contamination)' do
      other = Class.new(described_class) do
        id 'FA8888'
        severity :low
        confidence :low
        description 'Other rule'
      end

      expect(test_rule_class.id).to eq('FA9999')
      expect(test_rule_class.severity).to eq(:high)
      expect(other.id).to eq('FA8888')
      expect(other.severity).to eq(:low)
    end
  end

  # ── Constructor and protected readers ────────────────────────────────
  describe '#initialize' do
    it 'stores workspace, context_resolver, and configuration' do
      # Access protected readers through send
      expect(instance.send(:workspace)).to eq(workspace)
      expect(instance.send(:context_resolver)).to eq(context_resolver)
      expect(instance.send(:configuration)).to eq(configuration)
    end
  end

  describe 'protected readers' do
    it 'makes workspace accessible to subclasses' do
      sub = Class.new(described_class) do
        id 'FA7777'
        severity :low
        confidence :low
        description 'protected reader test'

        def exposed_workspace
          workspace
        end

        def analyze(call_sites:)
          []
        end
      end

      inst = sub.new(
        workspace: workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
      expect(inst.exposed_workspace).to eq(workspace)
    end

    it 'makes context_resolver accessible to subclasses' do
      sub = Class.new(described_class) do
        id 'FA7776'
        severity :low
        confidence :low
        description 'protected reader test 2'

        def exposed_resolver
          context_resolver
        end

        def analyze(call_sites:)
          []
        end
      end

      inst = sub.new(
        workspace: workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
      expect(inst.exposed_resolver).to eq(context_resolver)
    end

    it 'makes configuration accessible to subclasses' do
      sub = Class.new(described_class) do
        id 'FA7775'
        severity :low
        confidence :low
        description 'protected reader test 3'

        def exposed_configuration
          configuration
        end

        def analyze(call_sites:)
          []
        end
      end

      inst = sub.new(
        workspace: workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
      expect(inst.exposed_configuration).to eq(configuration)
    end
  end

  # ── #analyze ─────────────────────────────────────────────────────────
  describe '#analyze' do
    it 'raises NotImplementedError on the base class' do
      base_instance = described_class.new(
        workspace: workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
      expect { base_instance.analyze(call_sites: []) }
        .to raise_error(NotImplementedError)
    end

    it 'does not raise when subclass implements analyze' do
      expect { instance.analyze(call_sites: []) }.not_to raise_error
    end
  end

  # ── CONTEXT_CEILING table ────────────────────────────────────────────
  describe 'CONTEXT_CEILING' do
    subject(:table) { described_class::CONTEXT_CEILING }

    it 'is frozen' do
      expect(table).to be_frozen
    end

    it 'maps critical contexts correctly' do
      expect(table[:request]).to eq(:critical)
      expect(table[:middleware]).to eq(:critical)
      expect(table[:websocket]).to eq(:critical)
    end

    it 'maps high contexts correctly' do
      expect(table[:callback]).to eq(:high)
      expect(table[:view]).to eq(:high)
      expect(table[:job]).to eq(:high)
    end

    it 'maps boot to medium' do
      expect(table[:boot]).to eq(:medium)
    end

    it 'maps console and test to info' do
      expect(table[:console]).to eq(:info)
      expect(table[:test]).to eq(:info)
    end

    it 'maps rake_task to low' do
      expect(table[:rake_task]).to eq(:low)
    end

    it 'maps unknown to nil' do
      expect(table[:unknown]).to be_nil
    end
  end

  # ── severity_for (monotonic context ceiling) ────────────────────────
  describe '#severity_for (via analyze helper)' do
    # Helper to expose the private severity_for method
    let(:rule_with_severity_for) do
      klass = Class.new(described_class) do
        id 'FA6666'
        severity :medium
        confidence :high
        description 'severity_for test rule'

        def analyze(call_sites:)
          []
        end

        def call_severity_for(default_sev, context)
          severity_for(default_sev, context)
        end
      end

      klass.new(
        workspace: workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
    end

    context 'with no configuration override' do
      # Exhaustive ceiling table: rule default → context → expected result
      #
      # The monotonic rule: if severity is LESS severe than ceiling,
      # raise to ceiling. Never lower a more-severe default.
      #
      # Severity order (index): critical(0) > high(1) > medium(2) > low(3) > info(4)

      context 'request/middleware/websocket → :critical ceiling' do
        %i[request middleware websocket].each do |ctx|
          it "raises :high to :critical in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:high, ctx)).to eq(:critical)
          end

          it "raises :medium to :critical in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:medium, ctx)).to eq(:critical)
          end

          it "raises :low to :critical in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:low, ctx)).to eq(:critical)
          end

          it "raises :info to :critical in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:info, ctx)).to eq(:critical)
          end

          it "keeps :critical at :critical in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:critical, ctx)).to eq(:critical)
          end
        end
      end

      context 'callback/view/job → :high ceiling' do
        %i[callback view job].each do |ctx|
          it "keeps :critical at :critical in #{ctx} context (never lower)" do
            expect(rule_with_severity_for.call_severity_for(:critical, ctx)).to eq(:critical)
          end

          it "keeps :high at :high in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:high, ctx)).to eq(:high)
          end

          it "raises :medium to :high in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:medium, ctx)).to eq(:high)
          end

          it "raises :low to :high in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:low, ctx)).to eq(:high)
          end

          it "raises :info to :high in #{ctx} context" do
            expect(rule_with_severity_for.call_severity_for(:info, ctx)).to eq(:high)
          end
        end
      end

      context 'boot → :medium ceiling' do
        it 'keeps :critical at :critical (never lower)' do
          expect(rule_with_severity_for.call_severity_for(:critical, :boot)).to eq(:critical)
        end

        it 'keeps :high at :high (never lower)' do
          expect(rule_with_severity_for.call_severity_for(:high, :boot)).to eq(:high)
        end

        it 'keeps :medium at :medium' do
          expect(rule_with_severity_for.call_severity_for(:medium, :boot)).to eq(:medium)
        end

        it 'raises :low to :medium' do
          expect(rule_with_severity_for.call_severity_for(:low, :boot)).to eq(:medium)
        end

        it 'raises :info to :medium' do
          expect(rule_with_severity_for.call_severity_for(:info, :boot)).to eq(:medium)
        end
      end

      context 'console/test → :info ceiling' do
        %i[console test].each do |ctx|
          it 'keeps all severities unchanged (info is least severe)' do
            %i[critical high medium low info].each do |sev|
              expect(rule_with_severity_for.call_severity_for(sev, ctx)).to eq(sev)
            end
          end
        end
      end

      context 'rake_task → :low ceiling' do
        it 'keeps :critical at :critical (never lower)' do
          expect(rule_with_severity_for.call_severity_for(:critical, :rake_task)).to eq(:critical)
        end

        it 'keeps :high at :high' do
          expect(rule_with_severity_for.call_severity_for(:high, :rake_task)).to eq(:high)
        end

        it 'keeps :medium at :medium' do
          expect(rule_with_severity_for.call_severity_for(:medium, :rake_task)).to eq(:medium)
        end

        it 'keeps :low at :low' do
          expect(rule_with_severity_for.call_severity_for(:low, :rake_task)).to eq(:low)
        end

        it 'raises :info to :low' do
          expect(rule_with_severity_for.call_severity_for(:info, :rake_task)).to eq(:low)
        end
      end

      context 'unknown context → nil ceiling' do
        it 'does not raise severity for nil context (treated as unknown)' do
          expect(rule_with_severity_for.call_severity_for(:high, nil)).to eq(:high)
        end

        it 'does not raise severity for :unknown context' do
          expect(rule_with_severity_for.call_severity_for(:high, :unknown)).to eq(:high)
        end

        it 'leaves all severities unchanged under unknown' do
          %i[critical high medium low info].each do |sev|
            expect(rule_with_severity_for.call_severity_for(sev, :unknown)).to eq(sev)
          end
        end
      end

      context 'unrecognized context → treated as unknown' do
        it 'leaves severity unchanged for an unrecognized symbol' do
          expect(rule_with_severity_for.call_severity_for(:medium, :bogus_context)).to eq(:medium)
        end
      end
    end

    context 'with configuration severity override' do
      let(:override_config) do
        instance_double(FiberAudit::Configuration,
                        severity_override: :low,
                        rule_enabled?: true)
      end

      let(:rule_with_override) do
        klass = Class.new(described_class) do
          id 'FA5555'
          severity :high
          confidence :high
          description 'override test rule'

          def analyze(call_sites:)
            []
          end

          def call_severity_for(default_sev, context)
            severity_for(default_sev, context)
          end
        end

        klass.new(
          workspace: workspace,
          context_resolver: context_resolver,
          configuration: override_config
        )
      end

      it 'applies override before context ceiling' do
        # Override sets to :low, then request ceiling raises to :critical
        expect(rule_with_override.call_severity_for(:high, :request)).to eq(:critical)
      end

      it 'override replaces default entirely' do
        # Override sets to :low, unknown ceiling is nil → stays :low
        expect(rule_with_override.call_severity_for(:high, :unknown)).to eq(:low)
      end

      it 'context ceiling still applies on top of override' do
        # Override sets to :low, then callback ceiling raises to :high
        expect(rule_with_override.call_severity_for(:high, :callback)).to eq(:high)
      end

      it 'never lowers even with override' do
        # Override sets to :low, but :console ceiling is :info (less severe than :low)
        # So :low stays at :low (never lowered to :info)
        expect(rule_with_override.call_severity_for(:high, :console)).to eq(:low)
      end
    end

    context 'with nil configuration override' do
      let(:nil_override_config) do
        instance_double(FiberAudit::Configuration,
                        severity_override: nil,
                        rule_enabled?: true)
      end

      let(:rule_no_override) do
        klass = Class.new(described_class) do
          id 'FA4444'
          severity :medium
          confidence :high
          description 'no override test'

          def analyze(call_sites:)
            []
          end

          def call_severity_for(default_sev, context)
            severity_for(default_sev, context)
          end
        end

        klass.new(
          workspace: workspace,
          context_resolver: context_resolver,
          configuration: nil_override_config
        )
      end

      it 'uses the default severity when override is nil' do
        # No override, :request ceiling raises :medium to :critical
        expect(rule_no_override.call_severity_for(:medium, :request)).to eq(:critical)
      end

      it 'uses the default severity under unknown context' do
        expect(rule_no_override.call_severity_for(:medium, :unknown)).to eq(:medium)
      end
    end
  end

  # ── severity_index helper ────────────────────────────────────────────
  describe '#severity_index' do
    let(:rule_with_index) do
      klass = Class.new(described_class) do
        id 'FA3333'
        severity :medium
        confidence :high
        description 'severity_index test'

        def analyze(call_sites:)
          []
        end

        def call_severity_index(sev)
          severity_index(sev)
        end
      end

      klass.new(
        workspace: workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
    end

    it 'returns 0 for :critical' do
      expect(rule_with_index.call_severity_index(:critical)).to eq(0)
    end

    it 'returns 1 for :high' do
      expect(rule_with_index.call_severity_index(:high)).to eq(1)
    end

    it 'returns 2 for :medium' do
      expect(rule_with_index.call_severity_index(:medium)).to eq(2)
    end

    it 'returns 3 for :low' do
      expect(rule_with_index.call_severity_index(:low)).to eq(3)
    end

    it 'returns 4 for :info' do
      expect(rule_with_index.call_severity_index(:info)).to eq(4)
    end
  end

  # ── advisory_severity helper ────────────────────────────────────────
  describe '#advisory_severity (via analyze helper)' do
    # Helper to expose the private advisory_severity method
    let(:rule_with_advisory) do
      klass = Class.new(described_class) do
        id 'FA7777'
        severity :medium
        confidence :high
        description 'advisory_severity test rule'

        def analyze(call_sites:)
          []
        end

        def call_advisory_severity(default_sev)
          advisory_severity(default_sev)
        end
      end

      klass.new(
        workspace: workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
    end

    context 'with no configuration override' do
      it 'returns the default severity unchanged' do
        expect(rule_with_advisory.call_advisory_severity(:low)).to eq(:low)
      end

      it 'does not apply context ceiling (unlike severity_for)' do
        # advisory_severity should NOT escalate to :critical in request context
        # This is the key difference from severity_for
        %i[critical high medium low info].each do |sev|
          expect(rule_with_advisory.call_advisory_severity(sev)).to eq(sev)
        end
      end

      it 'normalizes String to Symbol' do
        expect(rule_with_advisory.call_advisory_severity('medium')).to eq(:medium)
      end
    end

    context 'with configuration severity override' do
      let(:override_config) do
        instance_double(FiberAudit::Configuration,
                        severity_override: :high,
                        rule_enabled?: true)
      end

      let(:rule_with_override) do
        klass = Class.new(described_class) do
          id 'FA6666'
          severity :medium
          confidence :high
          description 'advisory override test rule'

          def analyze(call_sites:)
            []
          end

          def call_advisory_severity(default_sev)
            advisory_severity(default_sev)
          end
        end

        klass.new(
          workspace: workspace,
          context_resolver: context_resolver,
          configuration: override_config
        )
      end

      it 'applies override replacing default' do
        # Override sets to :high, replaces :medium default
        expect(rule_with_override.call_advisory_severity(:medium)).to eq(:high)
      end

      it 'does not apply context ceiling even with override' do
        # Override sets to :high, but no context ceiling escalation
        expect(rule_with_override.call_advisory_severity(:low)).to eq(:high)
      end
    end
  end

  # ── Exhaustive monotonic table spec ──────────────────────────────────
  describe 'exhaustive monotonic ceiling table' do
    # This spec verifies the full severity × context matrix for one default
    # severity, ensuring the monotonic property holds for every combination.

    let(:rule_for_matrix) do
      klass = Class.new(described_class) do
        id 'FA2222'
        severity :medium
        confidence :high
        description 'matrix test'

        def analyze(call_sites:)
          []
        end

        def call_severity_for(default_sev, context)
          severity_for(default_sev, context)
        end
      end

      klass.new(
        workspace: workspace,
        context_resolver: context_resolver,
        configuration: configuration
      )
    end

    # All severity levels and all contexts
    SEVERITIES = %i[critical high medium low info].freeze
    CONTEXTS   = %i[request middleware websocket callback view job
                    boot console test rake_task unknown].freeze

    # Expected result matrix: [default_severity][context] = expected_severity
    EXPECTED = {
      critical: {
        request: :critical, middleware: :critical, websocket: :critical,
        callback: :critical, view: :critical, job: :critical,
        boot: :critical, console: :critical, test: :critical,
        rake_task: :critical, unknown: :critical
      },
      high: {
        request: :critical, middleware: :critical, websocket: :critical,
        callback: :high, view: :high, job: :high,
        boot: :high, console: :high, test: :high,
        rake_task: :high, unknown: :high
      },
      medium: {
        request: :critical, middleware: :critical, websocket: :critical,
        callback: :high, view: :high, job: :high,
        boot: :medium, console: :medium, test: :medium,
        rake_task: :medium, unknown: :medium
      },
      low: {
        request: :critical, middleware: :critical, websocket: :critical,
        callback: :high, view: :high, job: :high,
        boot: :medium, console: :low, test: :low,
        rake_task: :low, unknown: :low
      },
      info: {
        request: :critical, middleware: :critical, websocket: :critical,
        callback: :high, view: :high, job: :high,
        boot: :medium, console: :info, test: :info,
        rake_task: :low, unknown: :info
      }
    }.freeze

    SEVERITIES.each do |default_sev|
      CONTEXTS.each do |ctx|
        it "default=#{default_sev} + context=#{ctx} → #{EXPECTED[default_sev][ctx]}" do
          result = rule_for_matrix.call_severity_for(default_sev, ctx)
          expect(result).to eq(EXPECTED[default_sev][ctx])
        end
      end
    end

    it 'never produces a severity less severe than the input (monotonic invariant)' do
      SEVERITIES.each do |default_sev|
        CONTEXTS.each do |ctx|
          result = rule_for_matrix.call_severity_for(default_sev, ctx)
          expect(FiberAudit::Severity.index(result))
            .to be <= FiberAudit::Severity.index(default_sev),
                "severity_for(#{default_sev}, #{ctx}) = #{result} is less severe than #{default_sev}"
        end
      end
    end
  end
end

# rubocop:enable Lint/UnusedMethodArgument, Lint/ConstantDefinitionInBlock
