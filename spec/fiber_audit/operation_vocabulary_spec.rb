# frozen_string_literal: true

require 'fiber_audit/operation_vocabulary'
require 'fiber_audit/runtime/validation'
require 'fiber_audit/static/rules/blocking_subprocess'
require 'fiber_audit/static/rules/thread_join'
require 'fiber_audit/static/rules/synchronization'
require 'fiber_audit/static/rules/thread_current_state'
require 'fiber_audit/static/rules/io_select'
require 'fiber_audit/static/rules/direct_socket'
require 'fiber_audit/static/rules/net_http_in_request'
require 'fiber_audit/static/rules/blocking_fiber_context'

RSpec.describe FiberAudit::OperationVocabulary do
  it 'is the unchanged canonical source for FA1001 through FA1007' do
    expect(FiberAudit::Static::Rules::BlockingSubprocess::TARGETS).to equal(described_class::FA1001_TARGETS)
    expect(FiberAudit::Static::Rules::ThreadJoin::CANONICAL_OPS).to equal(described_class::FA1002_OPERATIONS)
    expect(FiberAudit::Static::Rules::Synchronization::TARGETS).to equal(described_class::FA1003_TARGETS)
    expect(FiberAudit::Static::Rules::ThreadCurrentState::THREAD_VARIABLE_METHODS)
      .to equal(described_class::FA1004_THREAD_VARIABLE_METHODS)
    expect(FiberAudit::Static::Rules::IOSelect::TARGETS).to equal(described_class::FA1005_TARGETS)
    expect(FiberAudit::Static::Rules::DirectSocket::EXACT).to equal(described_class::FA1006_EXACT)
    expect(FiberAudit::Static::Rules::NetHTTPInRequest::NET_HTTP_METHODS)
      .to equal(described_class::FA1007_NET_HTTP_METHODS)
  end

  it 'owns the canonical FA1008 static operation names' do
    expect(described_class::FA1008_OPERATIONS).to eq(
      fiber_new: 'Fiber.new(blocking: true)', fiber_blocking: 'Fiber.blocking'
    )
    expect(FiberAudit::Static::Rules::BlockingFiberContext::OPERATIONS)
      .to eq(described_class::FA1008_OPERATIONS.values)
    expect(FiberAudit::OperationSemantics.resolve('Fiber.new(blocking: true)'))
      .to have_attributes(category: :fiber_context, wait_possible: false, inventory_only: true)
  end

  it 'still defines FA1004_INDEX_METHODS for runtime vocabulary (even though static rule does not detect them)' do
    expect(described_class::FA1004_INDEX_METHODS).to eq(%i[\[\] \[\]=].freeze)
  end

  it 'FA1001_TARGETS includes the full subprocess lifecycle (Process.spawn, exec, wait*, Process::Status)' do
    expect(described_class::FA1001_TARGETS['Process']).to include(
      :spawn, :exec, :wait, :wait2, :waitpid, :waitpid2, :waitall, :detach
    )
    expect(described_class::FA1001_TARGETS['Process::Status']).to eq(%i[wait].freeze)
  end

  it 'accepts the frozen Thread.current index operations in runtime events' do
    expect(FiberAudit::Runtime::Validation.operation('Thread.thread_variable_get'))
      .to eq('Thread.thread_variable_get')
    expect(FiberAudit::Runtime::Validation.operation('Thread.thread_variable_set'))
      .to eq('Thread.thread_variable_set')
    expect(FiberAudit::Runtime::Validation.operation('Thread.current.[]')).to eq('Thread.current.[]')
    expect(FiberAudit::Runtime::Validation.operation('Thread.current.[]=')).to eq('Thread.current.[]=')
    expect { FiberAudit::Runtime::Validation.operation('Thread.current.secret') }
      .to raise_error(FiberAudit::RuntimeContractError)
  end
end
