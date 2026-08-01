# frozen_string_literal: true

# Test rules preserve the production keyword API even when call sites are not
# needed by registry-focused examples.
# rubocop:disable Lint/UnusedMethodArgument

require 'fiber_audit/static/rules/registry'
require 'fiber_audit/static/rules/base'
require 'fiber_audit/configuration'

RSpec.describe FiberAudit::Static::Rules::Registry do
  # ── Test rule subclasses ─────────────────────────────────────────────
  let(:rule_class_a) do
    Class.new(FiberAudit::Static::Rules::Base) do
      id 'FA1001'
      severity :high
      confidence :high
      description 'Rule A'

      def analyze(call_sites:)
        []
      end
    end
  end

  let(:rule_class_b) do
    Class.new(FiberAudit::Static::Rules::Base) do
      id 'FA1002'
      severity :medium
      confidence :medium
      description 'Rule B'

      def analyze(call_sites:)
        []
      end
    end
  end

  let(:rule_class_c) do
    Class.new(FiberAudit::Static::Rules::Base) do
      id 'FA1003'
      severity :low
      confidence :low
      description 'Rule C'

      def analyze(call_sites:)
        []
      end
    end
  end

  let(:workspace)        { double('workspace') }
  let(:context_resolver) { double('context_resolver') }
  let(:configuration) do
    instance_double(FiberAudit::Configuration,
                    rule_enabled?: true,
                    severity_override: nil)
  end

  # ── Constructor ──────────────────────────────────────────────────────
  describe '#initialize' do
    it 'accepts workspace and context_resolver as optional keyword arguments' do
      registry = described_class.new(workspace: workspace, context_resolver: context_resolver)
      expect(registry).to be_a(described_class)
    end

    it 'defaults workspace and context_resolver to nil' do
      registry = described_class.new
      expect(registry).to be_a(described_class)
    end

    it 'starts with an empty rule list' do
      registry = described_class.new
      expect(registry.list).to be_empty
    end
  end

  # ── #register ────────────────────────────────────────────────────────
  describe '#register' do
    let(:registry) do
      described_class.new(workspace: workspace, context_resolver: context_resolver)
    end

    it 'returns self for chaining' do
      result = registry.register(rule_class_a)
      expect(result).to eq(registry)
    end

    it 'allows chaining multiple registrations' do
      result = registry.register(rule_class_a).register(rule_class_b)
      expect(result).to eq(registry)
      expect(registry.list.size).to eq(2)
    end

    it 'adds the rule class to the registry' do
      registry.register(rule_class_a)
      expect(registry.list).to include(rule_class_a)
    end

    it 'maintains insertion order' do
      registry.register(rule_class_a)
      registry.register(rule_class_b)
      registry.register(rule_class_c)
      expect(registry.list).to eq([rule_class_a, rule_class_b, rule_class_c])
    end

    context 'validation' do
      it 'rejects non-Base classes' do
        expect { registry.register(String) }
          .to raise_error(ArgumentError, /must be a subclass of Base/)
      end

      it 'rejects classes that are not Class objects' do
        expect { registry.register('not a class') }
          .to raise_error(ArgumentError, /must be a subclass of Base/)
      end

      it 'rejects Base classes without an id' do
        no_id_class = Class.new(FiberAudit::Static::Rules::Base)
        expect { registry.register(no_id_class) }
          .to raise_error(ArgumentError, /must have an id set/)
      end

      it 'rejects duplicate rule IDs' do
        registry.register(rule_class_a)
        duplicate_class = Class.new(FiberAudit::Static::Rules::Base) do
          id 'FA1001'
          severity :low
          confidence :low
          description 'Duplicate'

          def analyze(call_sites:)
            []
          end
        end

        expect { registry.register(duplicate_class) }
          .to raise_error(ArgumentError, /already registered/)
      end

      it 'allows different rule IDs' do
        registry.register(rule_class_a)
        registry.register(rule_class_b)
        expect(registry.list.size).to eq(2)
      end
    end
  end

  # ── #[] and #find ────────────────────────────────────────────────────
  describe '#[]' do
    let(:registry) do
      described_class.new(workspace: workspace, context_resolver: context_resolver)
    end

    before do
      registry.register(rule_class_a)
      registry.register(rule_class_b)
    end

    it 'finds a rule class by string ID' do
      expect(registry['FA1001']).to eq(rule_class_a)
      expect(registry['FA1002']).to eq(rule_class_b)
    end

    it 'finds a rule class by symbol ID' do
      expect(registry[:FA1001]).to eq(rule_class_a)
      expect(registry[:FA1002]).to eq(rule_class_b)
    end

    it 'returns nil for unknown ID' do
      expect(registry['FA9999']).to be_nil
      expect(registry[:FA9999]).to be_nil
    end

    it 'returns nil for empty registry' do
      empty_registry = described_class.new
      expect(empty_registry['FA1001']).to be_nil
    end
  end

  describe '#find' do
    let(:registry) do
      described_class.new(workspace: workspace, context_resolver: context_resolver)
    end

    before do
      registry.register(rule_class_a)
    end

    it 'is an alias for []' do
      expect(registry.find('FA1001')).to eq(rule_class_a)
      expect(registry.find(:FA1001)).to eq(rule_class_a)
    end

    it 'returns nil for unknown ID' do
      expect(registry.find('FA9999')).to be_nil
    end
  end

  # ── #list ────────────────────────────────────────────────────────────
  describe '#list' do
    let(:registry) do
      described_class.new(workspace: workspace, context_resolver: context_resolver)
    end

    it 'returns an empty array when no rules are registered' do
      expect(registry.list).to eq([])
    end

    it 'returns all registered rule classes in insertion order' do
      registry.register(rule_class_a)
      registry.register(rule_class_b)
      registry.register(rule_class_c)

      expect(registry.list).to eq([rule_class_a, rule_class_b, rule_class_c])
    end

    it 'returns a duplicate-safe copy (not the internal array)' do
      registry.register(rule_class_a)
      list = registry.list
      list.clear
      expect(registry.list.size).to eq(1)
    end
  end

  # ── Enumerable ───────────────────────────────────────────────────────
  describe 'Enumerable' do
    let(:registry) do
      described_class.new(workspace: workspace, context_resolver: context_resolver)
    end

    before do
      registry.register(rule_class_a)
      registry.register(rule_class_b)
    end

    it 'includes Enumerable' do
      expect(described_class.ancestors).to include(Enumerable)
    end

    it 'supports each' do
      ids = registry.map(&:id)
      expect(ids).to eq(%w[FA1001 FA1002])
    end

    it 'supports map' do
      ids = registry.map(&:id)
      expect(ids).to eq(%w[FA1001 FA1002])
    end

    it 'supports select' do
      selected = registry.select { |rc| rc.id == 'FA1001' }
      expect(selected).to eq([rule_class_a])
    end

    it 'supports any?' do
      expect(registry.any? { |rc| rc.id == 'FA1001' }).to be true
      expect(registry.any? { |rc| rc.id == 'FA9999' }).to be false
    end

    it 'supports count' do
      expect(registry.count).to eq(2)
    end
  end

  # ── #enabled_for ─────────────────────────────────────────────────────
  describe '#enabled_for' do
    let(:registry) do
      described_class.new(workspace: workspace, context_resolver: context_resolver)
    end

    before do
      registry.register(rule_class_a)
      registry.register(rule_class_b)
      registry.register(rule_class_c)
    end

    context 'when all rules are enabled' do
      let(:all_enabled_config) do
        instance_double(FiberAudit::Configuration,
                        rule_enabled?: true,
                        severity_override: nil)
      end

      it 'returns instances of all registered rules' do
        instances = registry.enabled_for(all_enabled_config)
        expect(instances.size).to eq(3)
        expect(instances.map(&:class)).to eq([rule_class_a, rule_class_b, rule_class_c])
      end

      it 'initializes instances with registry dependencies' do
        instances = registry.enabled_for(all_enabled_config)
        instances.each do |instance|
          expect(instance.send(:workspace)).to eq(workspace)
          expect(instance.send(:context_resolver)).to eq(context_resolver)
          expect(instance.send(:configuration)).to eq(all_enabled_config)
        end
      end

      it 'returns Base instances (not classes)' do
        instances = registry.enabled_for(all_enabled_config)
        instances.each do |instance|
          expect(instance).to be_a(FiberAudit::Static::Rules::Base)
        end
      end
    end

    context 'when some rules are disabled' do
      let(:partial_config) do
        config = instance_double(FiberAudit::Configuration, severity_override: nil)
        allow(config).to receive(:rule_enabled?) do |rule_id|
          rule_id != 'FA1002'
        end
        config
      end

      it 'filters out disabled rules' do
        instances = registry.enabled_for(partial_config)
        expect(instances.size).to eq(2)
        expect(instances.map(&:class)).to eq([rule_class_a, rule_class_c])
      end

      it 'excludes disabled rule instances' do
        instances = registry.enabled_for(partial_config)
        ids = instances.map { |i| i.class.id }
        expect(ids).not_to include('FA1002')
      end
    end

    context 'when all rules are disabled' do
      let(:all_disabled_config) do
        instance_double(FiberAudit::Configuration,
                        rule_enabled?: false,
                        severity_override: nil)
      end

      it 'returns an empty array' do
        instances = registry.enabled_for(all_disabled_config)
        expect(instances).to eq([])
      end
    end

    context 'with empty registry' do
      let(:empty_registry) { described_class.new }

      it 'returns an empty array' do
        instances = empty_registry.enabled_for(configuration)
        expect(instances).to eq([])
      end
    end

    context 'dependency injection' do
      it 'passes workspace to each instance' do
        instances = registry.enabled_for(configuration)
        instances.each do |instance|
          expect(instance.send(:workspace)).to eq(workspace)
        end
      end

      it 'passes context_resolver to each instance' do
        instances = registry.enabled_for(configuration)
        instances.each do |instance|
          expect(instance.send(:context_resolver)).to eq(context_resolver)
        end
      end

      it 'passes configuration to each instance' do
        instances = registry.enabled_for(configuration)
        instances.each do |instance|
          expect(instance.send(:configuration)).to eq(configuration)
        end
      end
    end
  end

  # ── Class defaults immutability ──────────────────────────────────────
  describe 'class defaults immutability' do
    let(:registry) do
      described_class.new(workspace: workspace, context_resolver: context_resolver)
    end

    it 'does not mutate class defaults when creating instances' do
      original_severity = rule_class_a.severity
      original_confidence = rule_class_a.confidence

      registry.register(rule_class_a)
      registry.enabled_for(configuration)

      expect(rule_class_a.severity).to eq(original_severity)
      expect(rule_class_a.confidence).to eq(original_confidence)
    end

    it 'does not mutate class defaults even with configuration overrides' do
      override_config = instance_double(FiberAudit::Configuration,
                                        rule_enabled?: true,
                                        severity_override: :critical)

      original_severity = rule_class_a.severity

      registry.register(rule_class_a)
      registry.enabled_for(override_config)

      expect(rule_class_a.severity).to eq(original_severity)
    end
  end

  # ── Integration scenario ─────────────────────────────────────────────
  describe 'integration scenario' do
    it 'supports a complete workflow: register, find, enumerate, instantiate' do
      registry = described_class.new(workspace: workspace, context_resolver: context_resolver)

      # Register rules
      registry.register(rule_class_a)
      registry.register(rule_class_b)

      # Find by ID
      expect(registry['FA1001']).to eq(rule_class_a)

      # List all
      expect(registry.list.size).to eq(2)

      # Enumerate
      ids = registry.map(&:id)
      expect(ids).to eq(%w[FA1001 FA1002])

      # Instantiate enabled rules
      instances = registry.enabled_for(configuration)
      expect(instances.size).to eq(2)
      expect(instances.first).to be_a(FiberAudit::Static::Rules::Base)
      expect(instances.first.class.id).to eq('FA1001')
    end
  end
end

# rubocop:enable Lint/UnusedMethodArgument
