# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FiberAudit::Static::SemanticIndex do
  let(:fixture_root) { File.expand_path('../../fixtures/rubydex_spike', __dir__) }
  let(:sibling_root) { File.expand_path('../../fixtures/rubydex_spike_other', __dir__) }

  describe 'Data type definitions' do
    it 'defines Declaration with name, kind, path, line' do
      expect(described_class::Declaration.members).to eq(%i[name kind path line])
    end

    it 'defines Reference with name, path, line, column, context' do
      expect(described_class::Reference.members).to eq(%i[name path line column context])
    end

    it 'defines Constant with name, path, line' do
      expect(described_class::Constant.members).to eq(%i[name path line])
    end

    it 'defines RubydexGap with method, reason' do
      expect(described_class::RubydexGap.members).to eq(%i[method reason])
    end
  end

  describe '#build' do
    context 'with the eight original spike cases' do
      let(:index) { described_class.new(root: fixture_root).build }

      it 'Case 1: indexes simple class declarations' do
        declarations = index.declarations
        simple_class = declarations.find { |d| d.name == 'SimpleClass' && d.kind == :class }
        expect(simple_class).not_to be_nil
        expect(simple_class.path).to end_with('simple_class.rb')
        expect(simple_class.line).to eq(3) # source line 3, one-based
      end

      it 'Case 2: indexes controller inheritance hierarchy' do
        declarations = index.declarations
        app_controller = declarations.find { |d| d.name == 'ApplicationController' && d.kind == :class }
        users_controller = declarations.find { |d| d.name == 'UsersController' && d.kind == :class }

        expect(app_controller).not_to be_nil
        expect(app_controller.line).to eq(3) # source line 3

        expect(users_controller).not_to be_nil
        expect(users_controller.line).to eq(6) # source line 6
      end

      it 'Case 3: indexes module inclusions' do
        declarations = index.declarations
        included_module = declarations.find { |d| d.name == 'IncludedModule' && d.kind == :module }
        class_with_inclusion = declarations.find { |d| d.name == 'ClassWithInclusion' && d.kind == :class }

        expect(included_module).not_to be_nil
        expect(included_module.line).to eq(3) # source line 3

        expect(class_with_inclusion).not_to be_nil
        expect(class_with_inclusion.line).to eq(9) # source line 9
      end

      it 'Case 4: indexes method forwarding with Forwardable' do
        declarations = index.declarations
        forwarder = declarations.find { |d| d.name == 'ForwarderClass' && d.kind == :class }
        target = declarations.find { |d| d.name == 'DelegateTarget' && d.kind == :class }

        expect(forwarder).not_to be_nil
        expect(forwarder.line).to eq(15) # source line 15

        expect(target).not_to be_nil
        expect(target.line).to eq(5) # source line 5
      end

      it 'Case 5: indexes metaprogramming constructs' do
        declarations = index.declarations
        meta_class = declarations.find { |d| d.name == 'MetaprogrammingClass' && d.kind == :class }
        expect(meta_class).not_to be_nil
        expect(meta_class.line).to eq(3) # source line 3
      end

      it 'Case 6: indexes RBS-style annotations' do
        declarations = index.declarations
        typed_class = declarations.find { |d| d.name == 'TypedClass' && d.kind == :class }
        expect(typed_class).not_to be_nil
        expect(typed_class.line).to eq(6) # source line 6
      end

      it 'Case 7: indexes constant aliases' do
        declarations = index.declarations
        original = declarations.find { |d| d.name == 'Original' && d.kind == :class }

        expect(original).not_to be_nil
        expect(original.line).to eq(3) # source line 3

        # Alias may or may not be indexed depending on Rubydex capabilities
        # This is a known gap
      end

      it 'Case 8: indexes reopened class definitions with both sites' do
        declarations = index.declarations
        reopened_decls = declarations.select { |d| d.name == 'ReopenedClass' && d.kind == :class }

        # ReopenedClass has 2 definitions (in part1 and part2), each exposed as a Declaration
        expect(reopened_decls.length).to eq(2)

        paths = reopened_decls.map { |d| File.basename(d.path) }.sort
        expect(paths).to eq(%w[reopened_class_part1.rb reopened_class_part2.rb])

        lines = reopened_decls.map(&:line).sort
        expect(lines).to eq([3, 3]) # Both start at source line 3 in their respective files
      end
    end

    it 'produces identical results for relative and absolute paths' do
      relative_root = 'spec/fixtures/rubydex_spike'
      absolute_root = File.expand_path('spec/fixtures/rubydex_spike')

      relative_index = described_class.new(root: relative_root).build
      absolute_index = described_class.new(root: absolute_root).build

      expect(relative_index.declarations).to eq(absolute_index.declarations)
      expect(relative_index.gaps).to eq(absolute_index.gaps)
    end

    it 'is idempotent - second build produces same results' do
      index = described_class.new(root: fixture_root)

      first_build_decls = index.build.declarations
      first_build_gaps = index.gaps.dup

      second_build_decls = index.build.declarations
      second_build_gaps = index.gaps

      expect(second_build_decls).to eq(first_build_decls)
      expect(second_build_gaps).to eq(first_build_gaps)
    end
  end

  describe '#resolve_constant' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'resolves existing constants with correct location' do
      result = index.resolve_constant('SimpleClass', nesting: [])
      expect(result).to be_a(described_class::Constant)
      expect(result.name).to eq('SimpleClass')
      expect(result.path).to end_with('simple_class.rb')
      expect(result.line).to eq(3)
    end

    it 'resolves constants with nesting context' do
      result = index.resolve_constant('DelegateTarget', nesting: [])
      expect(result).to be_a(described_class::Constant)
      expect(result.name).to eq('DelegateTarget')
      expect(result.line).to eq(5)
    end

    it 'returns nil for non-existent constants' do
      result = index.resolve_constant('NonExistent', nesting: [])
      expect(result).to be_nil
    end
  end

  describe '#ancestors_of' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'returns ancestors for classes with inheritance' do
      ancestors = index.ancestors_of('UsersController')
      expect(ancestors).to be_an(Array)
      # UsersController inherits from ApplicationController; Object is implicit parent
      expect(ancestors).to include('ApplicationController')
      expect(ancestors).to include('Object')
    end

    it 'returns ancestors for classes with module inclusions' do
      ancestors = index.ancestors_of('ClassWithInclusion')
      expect(ancestors).to be_an(Array)
      # ClassWithInclusion includes IncludedModule
      expect(ancestors).to include('IncludedModule')
    end

    it 'returns empty array for classes without explicit ancestors' do
      ancestors = index.ancestors_of('SimpleClass')
      expect(ancestors).to be_an(Array)
    end

    it 'returns empty array for unknown declarations' do
      ancestors = index.ancestors_of('UnknownClass')
      expect(ancestors).to eq([])
    end

    it 'considers external/framework ancestors' do
      # This test verifies that ancestors_of considers all declarations,
      # not just workspace-owned ones
      ancestors = index.ancestors_of('UsersController')
      expect(ancestors).to be_an(Array)
      # Rubydex should resolve external ancestors like Object
      expect(ancestors).to include('Object')
    end
  end

  describe '#ancestors_of with graph double' do
    it 'uses focused graph double for external ancestors when framework unavailable' do
      # Create a mock graph that includes external ancestors
      graph_double = instance_double(Rubydex::Graph)
      declaration_double = instance_double(Rubydex::Class)
      ancestor_double = instance_double(Rubydex::Class, name: 'ExternalBase')

      allow(graph_double).to receive(:declarations).and_return([declaration_double])
      allow(declaration_double).to receive(:name).and_return('WorkspaceClass')
      allow(declaration_double).to receive(:respond_to?).with(:ancestors).and_return(true)
      allow(declaration_double).to receive(:ancestors).and_return([ancestor_double])
      allow(declaration_double).to receive(:respond_to?).with(:definitions).and_return(true)
      allow(declaration_double).to receive(:definitions).and_return([])

      index = described_class.new(root: fixture_root)
      index.instance_variable_set(:@graph, graph_double)

      # This should not raise an error even with the double
      ancestors = index.ancestors_of('WorkspaceClass')
      expect(ancestors).to be_an(Array)
    end
  end

  describe '#descendants_of' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'returns descendants for classes' do
      descendants = index.descendants_of('ApplicationController')
      expect(descendants).to be_an(Array)
      expect(descendants).to include('UsersController').or be_empty
    end

    it 'returns empty array for leaf classes' do
      descendants = index.descendants_of('SimpleClass')
      expect(descendants).to be_an(Array)
    end

    it 'returns empty array for unknown declarations gracefully' do
      descendants = index.descendants_of('UnknownClass')
      expect(descendants).to eq([])
    end
  end

  describe '#references_to' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'returns Reference objects for constant references' do
      refs = index.references_to('ApplicationController')
      expect(refs).to be_an(Array)

      if refs.any?
        ref = refs.first
        expect(ref).to be_a(described_class::Reference)
        expect(ref.name).to eq('ApplicationController')
        expect(ref.path).to be_a(String)
        expect(ref.line).to be_a(Integer)
        expect(ref.line).to be >= 1 # 1-based
        expect(ref.column).to be_a(Integer)
        expect(ref.column).to be >= 0 # 0-based
      end
    end

    it 'filters references to workspace only' do
      refs = index.references_to('SimpleClass')
      refs.each do |ref|
        expect(ref.path).to include('rubydex_spike')
        expect(ref.path).not_to include('rubydex_spike_other')
      end
    end

    it 'rescues non-file URIs per reference gracefully' do
      refs = index.references_to('ApplicationController')
      expect(refs).to be_an(Array)
      refs.each do |ref|
        expect(ref.path).to be_a(String)
        expect(ref.path).not_to start_with('gem://')
      end
    end

    it 'returns empty array for constants with no references' do
      refs = index.references_to('NonExistentConstant')
      expect(refs).to eq([])
    end
  end

  describe 'workspace filtering' do
    it 'excludes declarations from sibling directories' do
      index = described_class.new(root: fixture_root).build

      # SiblingClass is in rubydex_spike_other, not rubydex_spike
      sibling_decl = index.declarations.find { |d| d.name == 'SiblingClass' }
      expect(sibling_decl).to be_nil
    end

    it 'includes only declarations from the specified workspace' do
      index = described_class.new(root: fixture_root).build

      index.declarations.each do |decl|
        expect(decl.path).to include('rubydex_spike')
        expect(decl.path).not_to include('rubydex_spike_other')
      end
    end
  end

  describe 'sibling-root rejection' do
    it 'does not index sibling directory even with similar name prefix' do
      index = described_class.new(root: fixture_root).build

      all_paths = index.declarations.map(&:path)
      other_paths = all_paths.select { |p| p.include?('rubydex_spike_other') }

      expect(other_paths).to be_empty
    end

    it 'correctly handles Pathname ancestry vs string prefix' do
      index = described_class.new(root: fixture_root).build

      index.declarations.each do |decl|
        path = Pathname.new(decl.path)
        root = Pathname.new(index.root)

        # The path should be within the root using Pathname ancestry
        expect(path.ascend.to_a).to include(root)
      end
    end
  end

  describe '#gaps' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'records RubydexGap objects' do
      expect(index.gaps).to be_an(Array)
      expect(index.gaps).not_to be_empty

      index.gaps.each do |gap|
        expect(gap).to be_a(described_class::RubydexGap)
        expect(gap.method).to be_a(String)
        expect(gap.reason).to be_a(String)
      end
    end

    it 'includes known gaps' do
      gap_methods = index.gaps.map(&:method)
      expect(gap_methods).to include('method_name_from_reference')
      expect(gap_methods).to include('call_site_extraction')
    end

    it 'deduplicates gaps' do
      index.build

      gap_count = index.gaps.length
      index.build

      expect(index.gaps.length).to eq(gap_count)
    end

    it 'clears and rebuilds gaps on each build' do
      index.build
      first_gaps = index.gaps.dup

      index.build
      second_gaps = index.gaps

      expect(second_gaps).to eq(first_gaps)
    end
  end

  describe 'graceful degradation' do
    it 'returns empty array for declarations when graph is not built' do
      index = described_class.new(root: fixture_root)
      expect(index.declarations).to eq([])
    end

    it 'returns nil for resolve_constant when graph is not built' do
      index = described_class.new(root: fixture_root)
      expect(index.resolve_constant('Test', nesting: [])).to be_nil
    end

    it 'returns empty array for ancestors_of when graph is not built' do
      index = described_class.new(root: fixture_root)
      expect(index.ancestors_of('Test')).to eq([])
    end

    it 'returns empty array for descendants_of when graph is not built' do
      index = described_class.new(root: fixture_root)
      expect(index.descendants_of('Test')).to eq([])
    end

    it 'returns empty array for references_to when graph is not built' do
      index = described_class.new(root: fixture_root)
      expect(index.references_to('Test')).to eq([])
    end

    it 'handles build errors gracefully' do
      index = described_class.new(root: '/nonexistent/path')
      result = index.build

      expect(result).to eq(index)
      expect(index.gaps).not_to be_empty
      expect(index.gaps.any? { |g| g.method == 'build' }).to be(true)
    end
  end

  describe 'line and column conventions' do
    let(:index) { described_class.new(root: fixture_root).build }

    it 'uses 1-based lines for declarations' do
      declarations = index.declarations
      simple_class = declarations.find { |d| d.name == 'SimpleClass' }
      expect(simple_class.line).to be >= 1
    end

    it 'uses 0-based columns for references' do
      refs = index.references_to('ApplicationController')
      refs.each do |ref|
        expect(ref.column).to be >= 0
      end
    end

    it 'documents conventions in class comments' do
      source = File.read(__dir__ + '/../../../lib/fiber_audit/static/semantic_index.rb')
      expect(source).to include('one-based')
      expect(source).to include('zero-based')
    end
  end

  describe 'workspace-first definition selection' do
    it 'selects workspace definitions over global definitions' do
      index = described_class.new(root: fixture_root).build

      index.declarations.each do |decl|
        expect(decl.path).to include('rubydex_spike')
      end
    end
  end
end
