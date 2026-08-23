# frozen_string_literal: true

require 'fiber_audit/operation_semantics'
require 'fiber_audit/operation_vocabulary'

RSpec.describe FiberAudit::OperationSemantics do
  it 'covers every fixed canonical operation used by static and runtime analysis' do
    operations = []
    operations.concat(FiberAudit::OperationVocabulary::FA1001_TARGETS.flat_map do |constant, methods|
      methods.map { |method| "#{constant}.#{method}" }
    end)
    operations.concat(FiberAudit::OperationVocabulary::FA1002_OPERATIONS)
    operations.concat(FiberAudit::OperationVocabulary::FA1003_TARGETS.flat_map do |constant, methods|
      methods.map { |method| "#{constant}##{method}" }
    end)
    operations.push('Thread.thread_variable_get', 'Thread.thread_variable_set')
    operations.push('IO.select', 'Kernel.select')
    operations.concat(FiberAudit::OperationVocabulary::FA1006_EXACT.map { |constant| "#{constant}.new" })
    operations.push('Net::HTTP.get', 'Net::HTTP.get_response', 'Net::HTTP.start', 'Net::HTTP.request', 'URI.open',
                    'OpenURI.open_uri')

    expect(operations.uniq.reject { |operation| described_class.known?(operation) }).to be_empty
  end

  it 'distinguishes inventory, wait, optional capability, and socket constructor semantics' do
    expect(described_class.resolve('Kernel.spawn').to_h).to include(
      category: :creation, wait_possible: false, inventory_only: true, scheduler_capability: nil
    )
    expect(described_class.resolve('Process.waitpid').to_h).to include(
      category: :waiting, wait_possible: true, inventory_only: false, scheduler_capability: :process_wait
    )
    expect(described_class.resolve('ConditionVariable#wait').scheduler_capability).to eq(:kernel_sleep)
    expect(described_class.resolve('Socket.new').category).to eq(:socket_allocation)
    expect(described_class.resolve('TCPSocket.new').category).to eq(:socket_resolve_connect)
    expect(described_class.resolve('UNIXSocket.new').category).to eq(:socket_local_connect)
  end

  it 'requires a caller-proven socket path for dynamic constructor fallback' do
    ordinary = described_class.resolve('Project::ClientSocket.new')
    subclass = described_class.resolve_socket_constructor('Project::ClientSocket.new')
    unknown = described_class.resolve('Project.perform')

    runtime_subclass = described_class.resolve_runtime_operation('Project::ClientSocket.new')

    expect(ordinary).to equal(described_class::UNKNOWN)
    expect(subclass).to equal(described_class::SOCKET_SUBCLASS)
    expect(runtime_subclass).to equal(described_class::SOCKET_SUBCLASS)
    expect(subclass.wait_possible).to be(true)
    expect(unknown).to equal(described_class::UNKNOWN)
    expect(unknown.wait_possible).to be_nil
    expect(unknown.inventory_only).to be_nil
  end

  it 'returns immutable profiles and rejects malformed operations and profile fields' do
    expect(described_class.resolve('IO.select')).to be_frozen
    expect { described_class.resolve('') }.to raise_error(FiberAudit::RuntimeContractError)
    expect do
      described_class::Profile.new(category: :made_up, wait_possible: true, inventory_only: false)
    end.to raise_error(FiberAudit::RuntimeContractError, /category/)
  end
end
