# frozen_string_literal: true

require_relative 'errors'
require_relative 'operation_vocabulary'

module FiberAudit
  # Stable catalog boundary for operation profiles and scheduler requirements.
  # rubocop:disable Metrics/ModuleLength
  module OperationSemantics
    CAPABILITIES = %i[block kernel_sleep io_wait io_select process_wait address_resolve].freeze
    CORE_CAPABILITIES = %i[block kernel_sleep io_wait].freeze
    CAPABILITY_KINDS = %i[core optional].freeze
    CAPABILITY_APPLICABILITIES = %i[always conditional].freeze
    CATEGORIES = %i[
      creation replacement waiting detach stream thread_wait synchronization
      nonblocking_try thread_state io_select socket_allocation socket_resolve_connect
      socket_local_connect socket_constructor_unknown http_io fiber_context unknown
    ].freeze

    CapabilityRequirement = Data.define(:name, :kind, :applicability) do
      def initialize(name:, kind:, applicability: :always)
        normalized_name = name.to_sym if name.respond_to?(:to_sym)
        unless OperationSemantics::CAPABILITIES.include?(normalized_name)
          raise RuntimeContractError, "unknown scheduler capability: #{name.inspect}"
        end

        normalized_kind = kind.to_sym if kind.respond_to?(:to_sym)
        unless OperationSemantics::CAPABILITY_KINDS.include?(normalized_kind)
          raise RuntimeContractError, "unknown scheduler capability kind: #{kind.inspect}"
        end

        expected_kind = OperationSemantics::CORE_CAPABILITIES.include?(normalized_name) ? :core : :optional
        unless normalized_kind == expected_kind
          raise RuntimeContractError, "#{normalized_name} must use the #{expected_kind} capability kind"
        end

        normalized_applicability = applicability.to_sym if applicability.respond_to?(:to_sym)
        unless OperationSemantics::CAPABILITY_APPLICABILITIES.include?(normalized_applicability)
          raise RuntimeContractError, "unknown scheduler capability applicability: #{applicability.inspect}"
        end

        super(name: normalized_name, kind: normalized_kind, applicability: normalized_applicability)
      end

      def core? = kind == :core
      def optional? = kind == :optional
      def conditional? = applicability == :conditional
    end

    Profile = Data.define(:category, :wait_possible, :inventory_only, :scheduler_capability, :capabilities) do
      def initialize(category:, wait_possible:, inventory_only:, scheduler_capability: nil, capabilities: nil)
        normalized_category = category.to_sym if category.respond_to?(:to_sym)
        unless CATEGORIES.include?(normalized_category)
          raise RuntimeContractError,
                "unknown operation semantic category: #{category.inspect}"
        end

        [[:wait_possible, wait_possible], [:inventory_only, inventory_only]].each do |name, value|
          next if value.nil? || [true, false].include?(value)

          raise RuntimeContractError, "#{name} must be a Boolean or nil"
        end
        capability = scheduler_capability&.to_sym
        unless capability.nil? || CAPABILITIES.include?(capability)
          raise RuntimeContractError,
                "unknown scheduler capability: #{scheduler_capability.inspect}"
        end
        if capability && !capabilities.nil?
          raise RuntimeContractError,
                'scheduler_capability and capabilities are mutually exclusive'
        end

        requirements = if capabilities.nil?
                         capability ? [legacy_requirement(capability)] : []
                       else
                         normalize_requirements(capabilities)
                       end
        super(category: normalized_category, wait_possible: wait_possible, inventory_only: inventory_only,
              scheduler_capability: capability, capabilities: requirements.freeze)
      end

      def known? = category != :unknown
      def scheduler_capability_required? = !capabilities.empty?
      def core_capabilities = capabilities.select(&:core?).freeze
      def optional_capabilities = capabilities.select(&:optional?).freeze

      private

      def legacy_requirement(capability)
        CapabilityRequirement.new(name: capability, kind: CORE_CAPABILITIES.include?(capability) ? :core : :optional)
      end

      def normalize_requirements(values)
        unless values.is_a?(Array) && values.all?(CapabilityRequirement)
          raise RuntimeContractError, 'capabilities must be an Array of CapabilityRequirement values'
        end

        names = values.map(&:name)
        raise RuntimeContractError, 'capabilities must not contain duplicate names' unless names.uniq.size == names.size

        values.dup
      end
    end

    UNKNOWN = Profile.new(category: :unknown, wait_possible: nil, inventory_only: nil).freeze
    SOCKET_SUBCLASS = Profile.new(category: :socket_constructor_unknown, wait_possible: true, inventory_only: false).freeze
    IO_WAIT = CapabilityRequirement.new(name: :io_wait, kind: :core).freeze
    IO_SELECT = CapabilityRequirement.new(name: :io_select, kind: :optional, applicability: :conditional).freeze
    ADDRESS_RESOLVE = CapabilityRequirement.new(name: :address_resolve, kind: :optional, applicability: :conditional).freeze

    TABLE = {
      'Kernel.spawn' => [:creation, false, true], 'Process.spawn' => [:creation, false, true],
      'Kernel.exec' => [:replacement, false, true], 'Process.exec' => [:replacement, false, true],
      'Kernel.system' => [:waiting, true, false, :process_wait],
      'Process.wait' => [:waiting, true, false, :process_wait],
      'Process.wait2' => [:waiting, true, false, :process_wait],
      'Process.waitpid' => [:waiting, true, false, :process_wait],
      'Process.waitpid2' => [:waiting, true, false, :process_wait],
      'Process.waitall' => [:waiting, true, false, :process_wait],
      'Process::Status.wait' => [:waiting, true, false, :process_wait],
      'Open3.capture2' => [:waiting, true, false, :process_wait],
      'Open3.capture2e' => [:waiting, true, false, :process_wait],
      'Open3.capture3' => [:waiting, true, false, :process_wait],
      'Open3.pipeline' => [:waiting, true, false, :process_wait],
      'Process.detach' => [:detach, false, true], 'IO.popen' => [:stream, true, false],
      'Thread.join' => [:thread_wait, true, false, :block], 'Thread.value' => [:thread_wait, true, false, :block],
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:mutex_lock) =>
        [:synchronization, true, false, :block],
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:mutex_synchronize) =>
        [:synchronization, true, false, :block],
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:mutex_try_lock) =>
        [:nonblocking_try, false, false],
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:condition_wait) =>
        [:synchronization, true, false, :kernel_sleep],
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_synchronize) =>
        [:synchronization, true, false, :block],
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_mixin_synchronize) =>
        [:synchronization, true, false, :block],
      'Thread.thread_variable_get' => [:thread_state, false, true],
      'Thread.thread_variable_set' => [:thread_state, false, true],
      'Socket.new' => [:socket_allocation, false, true], 'IPSocket.new' => [:socket_allocation, false, true],
      'UDPSocket.new' => [:socket_allocation, false, true], 'UNIXServer.new' => [:socket_allocation, false, true]
    }.transform_values do |values|
      Profile.new(category: values[0], wait_possible: values[1], inventory_only: values[2],
                  scheduler_capability: values[3])
    end

    TABLE.merge!(
      'IO.select' => Profile.new(category: :io_select, wait_possible: true, inventory_only: false,
                                 capabilities: [IO_SELECT]),
      'Kernel.select' => Profile.new(category: :io_select, wait_possible: true, inventory_only: false,
                                     capabilities: [IO_SELECT]),
      'TCPSocket.new' => Profile.new(category: :socket_resolve_connect, wait_possible: true, inventory_only: false,
                                     capabilities: [IO_WAIT, ADDRESS_RESOLVE]),
      'TCPServer.new' => Profile.new(category: :socket_resolve_connect, wait_possible: true, inventory_only: false,
                                     capabilities: [IO_WAIT, ADDRESS_RESOLVE]),
      'UNIXSocket.new' => Profile.new(category: :socket_local_connect, wait_possible: true, inventory_only: false,
                                      capabilities: [IO_WAIT]),
      'Net::HTTP.get' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                     capabilities: [IO_WAIT, ADDRESS_RESOLVE]),
      'Net::HTTP.get_response' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                              capabilities: [IO_WAIT, ADDRESS_RESOLVE]),
      'Net::HTTP.start' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                       capabilities: [IO_WAIT, ADDRESS_RESOLVE]),
      'Net::HTTP.request' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                         capabilities: [IO_WAIT, ADDRESS_RESOLVE]),
      'URI.open' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                capabilities: [IO_WAIT, ADDRESS_RESOLVE]),
      'OpenURI.open_uri' => Profile.new(category: :http_io, wait_possible: true, inventory_only: false,
                                        capabilities: [IO_WAIT, ADDRESS_RESOLVE]),
      'Fiber.new(blocking: true)' => Profile.new(category: :fiber_context, wait_possible: false, inventory_only: true),
      'Fiber.blocking' => Profile.new(category: :fiber_context, wait_possible: false, inventory_only: true),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:mutex_unlock) => Profile.new(
        category: :synchronization, wait_possible: false, inventory_only: true
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:condition_signal) => Profile.new(
        category: :synchronization, wait_possible: false, inventory_only: true
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:condition_broadcast) => Profile.new(
        category: :synchronization, wait_possible: false, inventory_only: true
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_enter) => Profile.new(
        category: :synchronization, wait_possible: true, inventory_only: false, scheduler_capability: :block
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_synchronize) => Profile.new(
        category: :synchronization, wait_possible: true, inventory_only: false, scheduler_capability: :block
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_try_enter) => Profile.new(
        category: :nonblocking_try, wait_possible: false, inventory_only: false
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_exit) => Profile.new(
        category: :synchronization, wait_possible: false, inventory_only: true
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_mixin_enter) => Profile.new(
        category: :synchronization, wait_possible: true, inventory_only: false, scheduler_capability: :block
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_mixin_synchronize) => Profile.new(
        category: :synchronization, wait_possible: true, inventory_only: false, scheduler_capability: :block
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_mixin_try_enter) => Profile.new(
        category: :nonblocking_try, wait_possible: false, inventory_only: false
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_mixin_exit) => Profile.new(
        category: :synchronization, wait_possible: false, inventory_only: true
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_condition_wait) => Profile.new(
        category: :synchronization, wait_possible: true, inventory_only: false, scheduler_capability: :kernel_sleep
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_condition_signal) => Profile.new(
        category: :synchronization, wait_possible: false, inventory_only: true
      ),
      OperationVocabulary::RUNTIME_SYNCHRONIZATION_OPERATIONS.fetch(:monitor_condition_broadcast) => Profile.new(
        category: :synchronization, wait_possible: false, inventory_only: true
      )
    )
    TABLE.freeze

    FA1001_CATEGORIES = TABLE.slice(
      'Kernel.spawn', 'Process.spawn', 'Kernel.exec', 'Process.exec', 'Kernel.system', 'Process.wait',
      'Process.wait2', 'Process.waitpid', 'Process.waitpid2', 'Process.waitall', 'Process::Status.wait',
      'Open3.capture2', 'Open3.capture2e', 'Open3.capture3', 'Open3.pipeline', 'Process.detach', 'IO.popen'
    ).transform_values(&:category).freeze

    module_function

    def resolve(operation) = TABLE.fetch(normalize_operation(operation), UNKNOWN)
    def resolve_socket_constructor(operation) = resolve_with_socket_fallback(operation)
    def resolve_runtime_operation(operation) = resolve_with_socket_fallback(operation)
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
      TABLE.fetch(normalized) { socket_constructor_operation?(normalized) ? SOCKET_SUBCLASS : UNKNOWN }
    end
    private_class_method :resolve_with_socket_fallback
    def socket_constructor_operation?(operation) = operation.match?(/\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\.new\z/)
    private_class_method :socket_constructor_operation?
  end
  # rubocop:enable Metrics/ModuleLength
end
