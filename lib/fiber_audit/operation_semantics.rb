# frozen_string_literal: true

require_relative 'errors'

module FiberAudit
  # rubocop:disable Metrics/ModuleLength
  module OperationSemantics
    CAPABILITIES = %i[block kernel_sleep io_select process_wait address_resolve].freeze
    CATEGORIES = %i[
      creation replacement waiting detach stream thread_wait synchronization
      nonblocking_try thread_state io_select socket_allocation socket_resolve_connect
      socket_local_connect socket_constructor_unknown http_io unknown
    ].freeze

    Profile = Data.define(:category, :wait_possible, :inventory_only, :scheduler_capability) do
      def initialize(category:, wait_possible:, inventory_only:, scheduler_capability: nil)
        normalized_category = category.to_sym if category.respond_to?(:to_sym)
        unless CATEGORIES.include?(normalized_category)
          raise RuntimeContractError, "unknown operation semantic category: #{category.inspect}"
        end

        [[:wait_possible, wait_possible], [:inventory_only, inventory_only]].each do |name, value|
          next if value.nil? || [true, false].include?(value)

          raise RuntimeContractError, "#{name} must be a Boolean or nil"
        end

        capability = scheduler_capability&.to_sym
        unless capability.nil? || CAPABILITIES.include?(capability)
          raise RuntimeContractError, "unknown scheduler capability: #{scheduler_capability.inspect}"
        end

        super(category: normalized_category, wait_possible: wait_possible,
              inventory_only: inventory_only, scheduler_capability: capability)
      end

      def known? = category != :unknown
      def scheduler_capability_required? = !scheduler_capability.nil?
    end

    UNKNOWN = Profile.new(category: :unknown, wait_possible: nil, inventory_only: nil).freeze
    SOCKET_SUBCLASS = Profile.new(
      category: :socket_constructor_unknown,
      wait_possible: true,
      inventory_only: false
    ).freeze

    TABLE = {
      'Kernel.spawn' => Profile.new(category: :creation, wait_possible: false, inventory_only: true),
      'Process.spawn' => Profile.new(category: :creation, wait_possible: false, inventory_only: true),
      'Kernel.exec' => Profile.new(category: :replacement, wait_possible: false, inventory_only: true),
      'Process.exec' => Profile.new(category: :replacement, wait_possible: false, inventory_only: true),
      'Kernel.system' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                     scheduler_capability: :process_wait),
      'Process.wait' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                    scheduler_capability: :process_wait),
      'Process.wait2' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                     scheduler_capability: :process_wait),
      'Process.waitpid' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                       scheduler_capability: :process_wait),
      'Process.waitpid2' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                        scheduler_capability: :process_wait),
      'Process.waitall' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                       scheduler_capability: :process_wait),
      'Process::Status.wait' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                            scheduler_capability: :process_wait),
      'Open3.capture2' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                      scheduler_capability: :process_wait),
      'Open3.capture2e' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                       scheduler_capability: :process_wait),
      'Open3.capture3' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                      scheduler_capability: :process_wait),
      'Open3.pipeline' => Profile.new(category: :waiting, wait_possible: true, inventory_only: false,
                                      scheduler_capability: :process_wait),
      'Process.detach' => Profile.new(category: :detach, wait_possible: false, inventory_only: true),
      'IO.popen' => Profile.new(category: :stream, wait_possible: true, inventory_only: false),
      'Thread.join' => Profile.new(category: :thread_wait, wait_possible: true, inventory_only: false,
                                   scheduler_capability: :block),
      'Thread.value' => Profile.new(category: :thread_wait, wait_possible: true, inventory_only: false,
                                    scheduler_capability: :block),
      'Mutex#lock' => Profile.new(category: :synchronization, wait_possible: true, inventory_only: false,
                                  scheduler_capability: :block),
      'Mutex#synchronize' => Profile.new(category: :synchronization, wait_possible: true, inventory_only: false,
                                         scheduler_capability: :block),
      'Mutex#try_lock' => Profile.new(category: :nonblocking_try, wait_possible: false, inventory_only: false),
      'ConditionVariable#wait' => Profile.new(category: :synchronization, wait_possible: true,
                                              inventory_only: false, scheduler_capability: :kernel_sleep),
      'Monitor#synchronize' => Profile.new(category: :synchronization, wait_possible: true,
                                           inventory_only: false, scheduler_capability: :block),
      'MonitorMixin#synchronize' => Profile.new(category: :synchronization, wait_possible: true,
                                                inventory_only: false, scheduler_capability: :block),
      'Thread.thread_variable_get' => Profile.new(category: :thread_state, wait_possible: false,
                                                  inventory_only: true),
      'Thread.thread_variable_set' => Profile.new(category: :thread_state, wait_possible: false,
                                                  inventory_only: true),
      'IO.select' => Profile.new(category: :io_select, wait_possible: true, inventory_only: false,
                                 scheduler_capability: :io_select),
      'Kernel.select' => Profile.new(category: :io_select, wait_possible: true, inventory_only: false,
                                     scheduler_capability: :io_select),
      'Socket.new' => Profile.new(category: :socket_allocation, wait_possible: false, inventory_only: true),
      'IPSocket.new' => Profile.new(category: :socket_allocation, wait_possible: false, inventory_only: true),
      'UDPSocket.new' => Profile.new(category: :socket_allocation, wait_possible: false, inventory_only: true),
      'TCPSocket.new' => Profile.new(category: :socket_resolve_connect, wait_possible: true, inventory_only: false,
                                     scheduler_capability: :address_resolve),
      'TCPServer.new' => Profile.new(category: :socket_resolve_connect, wait_possible: true, inventory_only: false,
                                     scheduler_capability: :address_resolve),
      'UNIXSocket.new' => Profile.new(category: :socket_local_connect, wait_possible: true, inventory_only: false),
      'UNIXServer.new' => Profile.new(category: :socket_allocation, wait_possible: false, inventory_only: true),
      'Net::HTTP.get' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                     scheduler_capability: :address_resolve),
      'Net::HTTP.get_response' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                              scheduler_capability: :address_resolve),
      'Net::HTTP.start' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                       scheduler_capability: :address_resolve),
      'Net::HTTP.request' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                         scheduler_capability: :address_resolve),
      'URI.open' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                scheduler_capability: :address_resolve),
      'OpenURI.open_uri' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                        scheduler_capability: :address_resolve)
    }.freeze

    FA1001_CATEGORIES = TABLE.slice(
      'Kernel.spawn', 'Process.spawn', 'Kernel.exec', 'Process.exec', 'Kernel.system',
      'Process.wait', 'Process.wait2', 'Process.waitpid', 'Process.waitpid2',
      'Process.waitall', 'Process::Status.wait', 'Open3.capture2', 'Open3.capture2e',
      'Open3.capture3', 'Open3.pipeline', 'Process.detach', 'IO.popen'
    ).transform_values(&:category).freeze

    module_function

    def resolve(operation)
      TABLE.fetch(normalize_operation(operation), UNKNOWN)
    end

    def resolve_socket_constructor(operation)
      resolve_with_socket_fallback(operation)
    end

    # Runtime callers are the controlled targeted-probe registry; the only
    # canonical dynamic `<Class>.new` operations it emits are proven IPSocket
    # subclasses from Probes::Socket.
    def resolve_runtime_operation(operation)
      resolve_with_socket_fallback(operation)
    end

    def known?(operation) = resolve(operation).known?

    def normalize_operation(value)
      unless value.is_a?(String) && !value.empty? && value.valid_encoding? && value.bytesize <= 240
        raise RuntimeContractError, 'operation must be a non-empty UTF-8 String of at most 240 bytes'
      end

      value
    end
    private_class_method :normalize_operation

    def resolve_with_socket_fallback(operation)
      normalized = normalize_operation(operation)
      TABLE.fetch(normalized) do
        socket_constructor_operation?(normalized) ? SOCKET_SUBCLASS : UNKNOWN
      end
    end
    private_class_method :resolve_with_socket_fallback

    def socket_constructor_operation?(operation)
      operation.match?(/\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\.new\z/)
    end
    private_class_method :socket_constructor_operation?
  end
  # rubocop:enable Metrics/ModuleLength
end
