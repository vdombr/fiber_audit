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

RSpec.describe FiberAudit::OperationVocabulary do
  it 'is the unchanged canonical source for FA1001 through FA1007' do
    expect(FiberAudit::Static::Rules::BlockingSubprocess::TARGETS).to equal(described_class::FA1001_TARGETS)
    expect(FiberAudit::Static::Rules::ThreadJoin::CANONICAL_OPS).to equal(described_class::FA1002_OPERATIONS)
    expect(FiberAudit::Static::Rules::Synchronization::TARGETS).to equal(described_class::FA1003_TARGETS)
    expect(FiberAudit::Static::Rules::ThreadCurrentState::INDEX_METHODS)
      .to equal(described_class::FA1004_INDEX_METHODS)
    expect(FiberAudit::Static::Rules::IOSelect::TARGETS).to equal(described_class::FA1005_TARGETS)
    expect(FiberAudit::Static::Rules::DirectSocket::EXACT).to equal(described_class::FA1006_EXACT)
    expect(FiberAudit::Static::Rules::NetHTTPInRequest::NET_HTTP_METHODS)
      .to equal(described_class::FA1007_NET_HTTP_METHODS)
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
