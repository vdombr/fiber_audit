# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'

RSpec.describe 'supported Ruby scheduler semantics' do
  let(:script) { File.expand_path('../../../script/scheduler-semantics', __dir__) }

  it 'reproduces the scheduler and Fiber storage contracts' do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)

    expect(stderr).to eq('')
    expect(status).to be_success

    result = JSON.parse(stdout)
    expect(result).to include(
      'thread_join' => 'block',
      'mutex_contention' => 'block',
      'io_select' => 'io_select',
      'process_wait' => 'process_wait',
      'storage' => {
        'thread_index' => nil,
        'thread_variable' => 'parent_thread',
        'fiber_storage' => 'inherited_storage'
      },
      'rejected_scheduler_replacement' => { 'raised' => true, 'retained' => true }
    )
  end
end
