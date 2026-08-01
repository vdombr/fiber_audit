# frozen_string_literal: true

# Spec-local support constants intentionally model immutable public contracts.
# rubocop:disable Lint/ConstantDefinitionInBlock

require 'spec_helper'
require 'fiber_audit/static/execution_context_resolver'

RSpec.describe FiberAudit::Static::ExecutionContextResolver do
  # CallSite-compatible Data for testing (matches WP-2 contract)
  TestCallSite = Data.define(
    :path, :line, :column,
    :receiver_source, :receiver_constant, :method_name,
    :arguments, :enclosing_symbol, :nesting,
    :execution_context, :resolution, :confidence
  )

  def build_call_site(**attrs)
    defaults = {
      path: 'app/controllers/users_controller.rb',
      line: 10,
      column: 4,
      receiver_source: 'Open3',
      receiver_constant: 'Open3',
      method_name: :capture3,
      arguments: ['cmd'],
      enclosing_symbol: 'UsersController#index',
      nesting: ['UsersController'],
      execution_context: nil,
      resolution: 'Open3.capture3',
      confidence: :high
    }
    TestCallSite.new(**defaults, **attrs)
  end

  # Mock workspace that responds to ancestors_of
  class MockWorkspace
    def initialize(ancestors_map = {})
      @ancestors_map = ancestors_map
    end

    def ancestors_of(name)
      @ancestors_map.fetch(name, [])
    end
  end

  # Mock workspace that exposes semantic_index
  class MockWorkspaceWithSemanticIndex
    def initialize(semantic_index)
      @semantic_index = semantic_index
    end

    attr_reader :semantic_index
  end

  describe '#resolve(call_site:)' do
    context 'keyword-only invocation' do
      let(:workspace) { MockWorkspace.new }
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'requires call_site: keyword argument' do
        call_site = build_call_site
        expect(resolver.method(:resolve).parameters).to eq([%i[keyreq call_site]])
        expect { resolver.resolve(call_site: call_site) }.not_to raise_error
      end

      it 'raises ArgumentError when called without keyword' do
        call_site = build_call_site
        expect { resolver.resolve(call_site) }.to raise_error(ArgumentError)
      end

      it 'raises ArgumentError when called with wrong keyword name' do
        call_site = build_call_site
        expect { resolver.resolve(cs: call_site) }.to raise_error(ArgumentError)
      end
    end

    context 'semantic inheritance - request context' do
      let(:workspace) do
        MockWorkspace.new(
          'UsersController' => ['ActionController::Base', 'ApplicationController'],
          'ApplicationController' => ['ActionController::Base']
        )
      end
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves ActionController::Base descendant to :request' do
        call_site = build_call_site(
          enclosing_symbol: 'UsersController#index',
          nesting: ['UsersController']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end

      it 'resolves ActionController::API descendant to :request' do
        api_workspace = MockWorkspace.new(
          'ApiController' => ['ActionController::API']
        )
        api_resolver = described_class.new(workspace: api_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'ApiController#show',
          nesting: ['ApiController'],
          path: 'app/controllers/api_controller.rb'
        )
        expect(api_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end

      it 'handles indirect inheritance through ApplicationController' do
        call_site = build_call_site(
          enclosing_symbol: 'ApplicationController#base_action',
          nesting: ['ApplicationController']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end
    end

    context 'semantic inheritance - job context' do
      let(:workspace) do
        MockWorkspace.new(
          'ProcessOrderJob' => ['ActiveJob::Base', 'ApplicationJob'],
          'ApplicationJob' => ['ActiveJob::Base']
        )
      end
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves ActiveJob::Base descendant to :job' do
        call_site = build_call_site(
          enclosing_symbol: 'ProcessOrderJob#perform',
          nesting: ['ProcessOrderJob'],
          path: 'app/jobs/process_order_job.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::JOB)
      end

      it 'tolerates ActionJob::Base typo to :job' do
        typo_workspace = MockWorkspace.new(
          'TypoJob' => ['ActionJob::Base']
        )
        typo_resolver = described_class.new(workspace: typo_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'TypoJob#perform',
          nesting: ['TypoJob'],
          path: 'app/jobs/typo_job.rb'
        )
        expect(typo_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::JOB)
      end
    end

    context 'semantic inheritance - websocket context' do
      let(:workspace) do
        MockWorkspace.new(
          'ChatChannel' => ['ActionCable::Channel::Base']
        )
      end
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves ActionCable::Channel::Base descendant to :websocket' do
        call_site = build_call_site(
          enclosing_symbol: 'ChatChannel#speak',
          nesting: ['ChatChannel'],
          path: 'app/channels/chat_channel.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::WEBSOCKET)
      end
    end

    context 'semantic inheritance - view context' do
      let(:workspace) do
        MockWorkspace.new(
          'UsersHelper' => ['ActionView::Base']
        )
      end
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves ActionView::Base descendant to :view' do
        call_site = build_call_site(
          enclosing_symbol: 'UsersHelper#format_name',
          nesting: ['UsersHelper'],
          path: 'app/helpers/users_helper.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::VIEW)
      end
    end

    context 'path-based fallback' do
      let(:workspace) { MockWorkspace.new }
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves config/initializers to :boot' do
        call_site = build_call_site(
          path: 'config/initializers/session_store.rb',
          enclosing_symbol: 'SessionStore#configure',
          nesting: ['SessionStore']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::BOOT)
      end

      it 'resolves lib/tasks to :rake_task' do
        call_site = build_call_site(
          path: 'lib/tasks/deploy.rake',
          enclosing_symbol: 'DeployTask#run',
          nesting: []
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::RAKE_TASK)
      end

      it 'resolves Rakefile basename to :rake_task' do
        call_site = build_call_site(
          path: 'Rakefile',
          enclosing_symbol: 'main',
          nesting: []
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::RAKE_TASK)
      end

      it 'resolves app/views to :view' do
        call_site = build_call_site(
          path: 'app/views/users/index.html.erb',
          enclosing_symbol: 'UsersView#render',
          nesting: []
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::VIEW)
      end

      it 'resolves spec segment to :test' do
        call_site = build_call_site(
          path: 'spec/models/user_spec.rb',
          enclosing_symbol: 'UserSpec#tests',
          nesting: ['UserSpec']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::TEST)
      end

      it 'resolves test segment to :test' do
        call_site = build_call_site(
          path: 'test/models/user_test.rb',
          enclosing_symbol: 'UserTest#test_valid',
          nesting: ['UserTest']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::TEST)
      end

      it 'does NOT resolve my_spec.rb without spec segment to :test' do
        call_site = build_call_site(
          path: 'app/services/my_spec_helper.rb',
          enclosing_symbol: 'MySpecHelper#help',
          nesting: ['MySpecHelper']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'resolves config.ru with instance #call to :middleware' do
        call_site = build_call_site(
          path: 'config.ru',
          enclosing_symbol: 'MyMiddleware#call',
          nesting: ['MyMiddleware']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::MIDDLEWARE)
      end

      it 'does NOT resolve config.ru with class method .call to :middleware' do
        call_site = build_call_site(
          path: 'config.ru',
          enclosing_symbol: 'AppBuilder.call',
          nesting: []
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'does NOT resolve config.ru without #call to :middleware' do
        call_site = build_call_site(
          path: 'config.ru',
          enclosing_symbol: 'AppBuilder#build',
          nesting: []
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'does NOT resolve config.ru with #callback (substring false positive) to :middleware' do
        call_site = build_call_site(
          path: 'config.ru',
          enclosing_symbol: 'AppBuilder#callback',
          nesting: ['AppBuilder']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end
    end

    context 'callback DSL detection' do
      let(:workspace) do
        MockWorkspace.new(
          'User' => ['ActiveRecord::Base']
        )
      end
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves before_ callback with AR ancestry to :callback' do
        call_site = build_call_site(
          enclosing_symbol: 'User#before_save',
          nesting: ['User'],
          path: 'app/models/user.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::CALLBACK)
      end

      it 'resolves after_ callback with AR ancestry to :callback' do
        call_site = build_call_site(
          enclosing_symbol: 'User#after_create',
          nesting: ['User'],
          path: 'app/models/user.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::CALLBACK)
      end

      it 'resolves around_ callback with AR ancestry to :callback' do
        call_site = build_call_site(
          enclosing_symbol: 'User#around_update',
          nesting: ['User'],
          path: 'app/models/user.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::CALLBACK)
      end

      it 'does NOT resolve before_ without model ancestry' do
        poro_workspace = MockWorkspace.new('ServiceClass' => [])
        poro_resolver = described_class.new(workspace: poro_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'ServiceClass#before_process',
          nesting: ['ServiceClass'],
          path: 'app/services/service_class.rb'
        )
        expect(poro_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'does NOT resolve before_ with only ActiveSupport::Concern ancestry' do
        concern_workspace = MockWorkspace.new('MyModule' => ['ActiveSupport::Concern'])
        concern_resolver = described_class.new(workspace: concern_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'MyModule#before_compile',
          nesting: ['MyModule']
        )
        expect(concern_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end
    end

    context 'precedence: inheritance > path > callback' do
      let(:workspace) do
        MockWorkspace.new(
          'TestController' => ['ActionController::Base']
        )
      end
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'semantic :request outranks spec path :test' do
        call_site = build_call_site(
          path: 'spec/controllers/test_controller_spec.rb',
          enclosing_symbol: 'TestController#index',
          nesting: ['TestController']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end
    end

    context 'PORO unknown' do
      let(:workspace) { MockWorkspace.new }
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves plain Ruby object to :unknown' do
        call_site = build_call_site(
          path: 'app/services/plain_service.rb',
          enclosing_symbol: 'PlainService#process',
          nesting: ['PlainService']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end
    end

    context 'adapter errors' do
      it 'returns :unknown when workspace raises' do
        error_workspace = MockWorkspace.new
        allow(error_workspace).to receive(:ancestors_of).and_raise(StandardError, 'boom')
        resolver = described_class.new(workspace: error_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'User#before_save',
          nesting: ['User']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'returns :unknown when call_site is malformed' do
        resolver = described_class.new(workspace: MockWorkspace.new)
        malformed = Object.new
        expect(resolver.resolve(call_site: malformed)).to eq(FiberAudit::Context::UNKNOWN)
      end
    end

    context 'workspace with semantic_index' do
      let(:semantic_index) do
        instance_double('SemanticIndex', ancestors_of: ['ActionController::Base'])
      end
      let(:workspace) { MockWorkspaceWithSemanticIndex.new(semantic_index) }
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'delegates to workspace.semantic_index.ancestors_of' do
        call_site = build_call_site(
          enclosing_symbol: 'UsersController#index',
          nesting: ['UsersController']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end

      it 'never raises even if semantic_index raises' do
        broken_index = double('BrokenIndex')
        allow(broken_index).to receive(:ancestors_of).and_raise(StandardError, 'index error')
        broken_workspace = MockWorkspaceWithSemanticIndex.new(broken_index)
        broken_resolver = described_class.new(workspace: broken_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'UsersController#index',
          nesting: ['UsersController']
        )
        expect(broken_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end
    end

    context 'transitive semantic traversal' do
      let(:workspace) do
        MockWorkspace.new(
          'Admin::Base' => ['ApplicationController', 'ActionController::Base'],
          'ApplicationController' => ['ActionController::Base'],
          'Admin::UsersController' => ['Admin::Base', 'ApplicationController']
        )
      end
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves through multiple inheritance levels transitively' do
        call_site = build_call_site(
          enclosing_symbol: 'Admin::UsersController#index',
          nesting: ['Admin', 'Admin::UsersController'],
          path: 'app/controllers/admin/users_controller.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end

      it 'resolves deeply nested indirect inheritance' do
        deep_workspace = MockWorkspace.new(
          'Level1' => ['Level2'],
          'Level2' => ['Level3'],
          'Level3' => ['Level4'],
          'Level4' => ['ActionController::Base']
        )
        deep_resolver = described_class.new(workspace: deep_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'Level1#action',
          nesting: ['Level1']
        )
        expect(deep_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end
    end

    context 'cyclic ancestor detection' do
      it 'handles cyclic ancestors without infinite recursion' do
        cyclic_workspace = MockWorkspace.new(
          'ClassA' => ['ClassB'],
          'ClassB' => ['ClassA'] # cycle: A -> B -> A
        )
        cyclic_resolver = described_class.new(workspace: cyclic_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'ClassA#method',
          nesting: ['ClassA']
        )
        # Should not hang, returns :unknown since no signal found
        expect(cyclic_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'handles self-referencing ancestors' do
        self_ref_workspace = MockWorkspace.new(
          'SelfRef' => ['SelfRef']
        )
        self_ref_resolver = described_class.new(workspace: self_ref_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'SelfRef#method',
          nesting: ['SelfRef']
        )
        expect(self_ref_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'finds signal through cycle if ancestor is a signal' do
        cycle_with_signal_workspace = MockWorkspace.new(
          'ClassX' => ['ClassY', 'ActionController::Base'],
          'ClassY' => ['ClassX'] # cycle: Y -> X, but X has signal ancestor
        )
        cycle_resolver = described_class.new(workspace: cycle_with_signal_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'ClassX#action',
          nesting: ['ClassX']
        )
        expect(cycle_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end
    end

    context 'known class itself as signal' do
      it 'matches class itself even when ancestors list is empty' do
        # Class IS ActionController::Base itself - ancestors_of returns []
        # but the class name itself is a signal
        empty_ancestors_workspace = MockWorkspace.new(
          'ActionController::Base' => []
        )
        empty_resolver = described_class.new(workspace: empty_ancestors_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'ActionController::Base#render',
          nesting: ['ActionController::Base']
        )
        expect(empty_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::REQUEST)
      end

      it 'matches ActiveJob::Base itself with empty ancestors' do
        empty_workspace = MockWorkspace.new(
          'ActiveJob::Base' => []
        )
        empty_resolver = described_class.new(workspace: empty_workspace)
        call_site = build_call_site(
          enclosing_symbol: 'ActiveJob::Base#perform',
          nesting: ['ActiveJob::Base'],
          path: 'activejob/base.rb'
        )
        expect(empty_resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::JOB)
      end
    end

    context 'noncontiguous path false positives' do
      let(:workspace) { MockWorkspace.new }
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'does NOT match non-contiguous config/initializers' do
        call_site = build_call_site(
          path: 'app/config/services/initializers_helper.rb',
          enclosing_symbol: 'InitializersHelper#run',
          nesting: ['InitializersHelper']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'does NOT match non-contiguous lib/tasks' do
        call_site = build_call_site(
          path: 'app/lib/services/tasks_runner.rb',
          enclosing_symbol: 'TasksRunner#run',
          nesting: ['TasksRunner']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'does NOT match non-contiguous app/views' do
        call_site = build_call_site(
          path: 'app/services/views_registry.rb',
          enclosing_symbol: 'ViewsRegistry#register',
          nesting: ['ViewsRegistry']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end
    end

    context 'Windows backslash paths' do
      let(:workspace) { MockWorkspace.new }
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'resolves config\\initializers to :boot' do
        call_site = build_call_site(
          path: 'config\\initializers\\session_store.rb',
          enclosing_symbol: 'SessionStore#configure',
          nesting: ['SessionStore']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::BOOT)
      end

      it 'resolves lib\\tasks to :rake_task' do
        call_site = build_call_site(
          path: 'lib\\tasks\\deploy.rake',
          enclosing_symbol: 'DeployTask#run',
          nesting: []
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::RAKE_TASK)
      end

      it 'resolves app\\views to :view' do
        call_site = build_call_site(
          path: 'app\\views\\users\\index.html.erb',
          enclosing_symbol: 'UsersView#render',
          nesting: []
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::VIEW)
      end

      it 'resolves mixed separators to :boot' do
        call_site = build_call_site(
          path: 'config/initializers\\session_store.rb',
          enclosing_symbol: 'SessionStore#configure',
          nesting: ['SessionStore']
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::BOOT)
      end
    end

    context 'class method enclosing symbol' do
      let(:workspace) do
        MockWorkspace.new(
          'UserService' => ['ActiveRecord::Base']
        )
      end
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'extracts class from ClassName.method format' do
        call_site = build_call_site(
          enclosing_symbol: 'UserService.before_save',
          nesting: ['UserService'],
          path: 'app/models/user_service.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::CALLBACK)
      end
    end

    context 'empty or nil enclosing_symbol' do
      let(:workspace) { MockWorkspace.new }
      let(:resolver) { described_class.new(workspace: workspace) }

      it 'handles nil enclosing_symbol gracefully' do
        call_site = build_call_site(
          enclosing_symbol: nil,
          nesting: [],
          path: 'app/services/service.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end

      it 'handles empty enclosing_symbol gracefully' do
        call_site = build_call_site(
          enclosing_symbol: '',
          nesting: [],
          path: 'app/services/service.rb'
        )
        expect(resolver.resolve(call_site: call_site)).to eq(FiberAudit::Context::UNKNOWN)
      end
    end
  end

  describe '#resolve_all(call_sites:)' do
    let(:workspace) do
      MockWorkspace.new(
        'UsersController' => ['ActionController::Base'],
        'ProcessOrderJob' => ['ActiveJob::Base']
      )
    end
    let(:resolver) { described_class.new(workspace: workspace) }

    context 'keyword-only invocation' do
      it 'requires call_sites: keyword argument' do
        call_sites = [build_call_site(enclosing_symbol: 'UsersController#index', nesting: ['UsersController'])]
        expect(resolver.method(:resolve_all).parameters).to eq([%i[keyreq call_sites]])
        expect { resolver.resolve_all(call_sites: call_sites) }.not_to raise_error
      end

      it 'raises ArgumentError when called without keyword' do
        call_sites = [build_call_site]
        expect { resolver.resolve_all(call_sites) }.to raise_error(ArgumentError)
      end
    end

    it 'returns a new array in original order' do
      call_sites = [
        build_call_site(enclosing_symbol: 'UsersController#index', nesting: ['UsersController']),
        build_call_site(enclosing_symbol: 'ProcessOrderJob#perform', nesting: ['ProcessOrderJob'], path: 'app/jobs/job.rb'),
        build_call_site(enclosing_symbol: 'PlainService#process', nesting: ['PlainService'])
      ]

      result = resolver.resolve_all(call_sites: call_sites)

      expect(result).to be_an(Array)
      expect(result).not_to be(call_sites)
      expect(result.size).to eq(3)
      expect(result[0].execution_context).to eq(FiberAudit::Context::REQUEST)
      expect(result[1].execution_context).to eq(FiberAudit::Context::JOB)
      expect(result[2].execution_context).to eq(FiberAudit::Context::UNKNOWN)
    end

    it 'returns immutable CallSite copies with execution_context populated' do
      call_sites = [
        build_call_site(enclosing_symbol: 'UsersController#index', nesting: ['UsersController'])
      ]

      result = resolver.resolve_all(call_sites: call_sites)
      original = call_sites.first
      copied = result.first

      expect(copied.execution_context).to eq(FiberAudit::Context::REQUEST)
      expect(original.execution_context).to be_nil
      expect(copied.path).to eq(original.path)
      expect(copied.line).to eq(original.line)
      expect(copied.method_name).to eq(original.method_name)
    end

    it 'does not mutate original call sites' do
      call_sites = [
        build_call_site(enclosing_symbol: 'UsersController#index', nesting: ['UsersController'])
      ]
      original_context = call_sites.first.execution_context

      resolver.resolve_all(call_sites: call_sites)

      expect(call_sites.first.execution_context).to eq(original_context)
    end

    it 'handles empty array' do
      expect(resolver.resolve_all(call_sites: [])).to eq([])
    end

    it 'handles nil gracefully' do
      expect(resolver.resolve_all(call_sites: nil)).to eq([])
    end

    it 'returns :unknown for all when workspace raises' do
      error_workspace = MockWorkspace.new
      allow(error_workspace).to receive(:ancestors_of).and_raise(StandardError)
      error_resolver = described_class.new(workspace: error_workspace)

      call_sites = [
        build_call_site(enclosing_symbol: 'User#before_save', nesting: ['User'])
      ]

      result = error_resolver.resolve_all(call_sites: call_sites)
      expect(result.first.execution_context).to eq(FiberAudit::Context::UNKNOWN)
    end

    context 'actual merged FiberAudit::Static::CallSite copying' do
      it 'copies real FiberAudit::Static::CallSite objects' do
        # Use the actual CallSite Data type if available
        call_site = FiberAudit::Static::CallSite.new(
          path: 'app/controllers/users_controller.rb',
          line: 10,
          column: 4,
          receiver_source: 'Open3',
          receiver_constant: 'Open3',
          method_name: :capture3,
          arguments: ['cmd'],
          enclosing_symbol: 'UsersController#index',
          nesting: ['UsersController'],
          execution_context: nil,
          resolution: 'Open3.capture3',
          confidence: :high
        )

        result = resolver.resolve_all(call_sites: [call_site])

        expect(result.size).to eq(1)
        copied = result.first
        expect(copied).not_to be(call_site)
        expect(copied).to be_a(FiberAudit::Static::CallSite)
        expect(copied.execution_context).to eq(FiberAudit::Context::REQUEST)
        expect(copied.path).to eq(call_site.path)
        expect(copied.line).to eq(call_site.line)
        expect(copied.method_name).to eq(call_site.method_name)
        expect(copied.receiver_source).to eq(call_site.receiver_source)
        # Original unchanged
        expect(call_site.execution_context).to be_nil
      end
    end
  end

  describe 'standalone require' do
    it 'can be required without full gem' do
      expect(defined?(FiberAudit::Static::ExecutionContextResolver)).to eq('constant')
      expect(defined?(FiberAudit::Context)).to eq('constant')
    end
  end

  describe 'Context constants' do
    it 'defines all expected contexts' do
      expect(FiberAudit::Context::REQUEST).to eq(:request)
      expect(FiberAudit::Context::MIDDLEWARE).to eq(:middleware)
      expect(FiberAudit::Context::CALLBACK).to eq(:callback)
      expect(FiberAudit::Context::VIEW).to eq(:view)
      expect(FiberAudit::Context::JOB).to eq(:job)
      expect(FiberAudit::Context::WEBSOCKET).to eq(:websocket)
      expect(FiberAudit::Context::BOOT).to eq(:boot)
      expect(FiberAudit::Context::CONSOLE).to eq(:console)
      expect(FiberAudit::Context::RAKE_TASK).to eq(:rake_task)
      expect(FiberAudit::Context::TEST).to eq(:test)
      expect(FiberAudit::Context::UNKNOWN).to eq(:unknown)
    end

    it 'ALL is frozen and contains all contexts in order' do
      expect(FiberAudit::Context::ALL).to be_frozen
      expect(FiberAudit::Context::ALL.size).to eq(11)
      expect(FiberAudit::Context::ALL).to eq(%i[
                                               request middleware callback view job websocket
                                               boot console rake_task test unknown
                                             ])
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock
