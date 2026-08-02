# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/static/semantic_index'
require 'fiber_audit/static/call_site_extractor'
require 'fiber_audit/static/execution_context_resolver'

RSpec.describe 'rails execution context fixture' do
  it 'classifies every supported static context' do
    root = File.expand_path('../../fixtures/apps/rails_contexts', __dir__)
    files = Dir.glob(File.join(root, '**', '*')).select do |path|
      File.file?(path) && (path.end_with?('.rb', '.rake') || File.basename(path) == 'config.ru')
    end.sort
    semantic_index = FiberAudit::Static::SemanticIndex.new(root: root).build
    extracted = FiberAudit::Static::CallSiteExtractor.new(
      files: files,
      semantic_index: semantic_index
    ).call
    relative_sites = extracted.call_sites.map do |site|
      relative_path = site.path.delete_prefix("#{root}/")
      FiberAudit::Static::CallSite.new(**site.to_h, path: relative_path)
    end
    resolved = FiberAudit::Static::ExecutionContextResolver
               .new(workspace: semantic_index)
               .resolve_all(call_sites: relative_sites)

    contexts = resolved.select { |site| site.method_name == :puts }.to_h do |site|
      [site.path, site.execution_context]
    end

    expect(contexts).to include(
      'app/controllers/users_controller.rb' => :request,
      'app/jobs/sample_job.rb' => :job,
      'app/channels/sample_channel.rb' => :websocket,
      'app/models/sample_record.rb' => :callback,
      'config/initializers/sample.rb' => :boot,
      'lib/tasks/sample.rake' => :rake_task,
      'app/views/users/index.rb' => :view,
      'config.ru' => :middleware
    )
  end
end
