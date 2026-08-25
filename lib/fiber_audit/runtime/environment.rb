# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'pathname'
require 'securerandom'
require_relative 'policy'
require_relative 'validation'
require_relative 'watchdog_policy'
require_relative 'operation_liveness_policy'
require_relative 'synchronization_graph_policy'
require_relative 'process_progress_policy'

module FiberAudit
  module Runtime
    # rubocop:disable Metrics/ModuleLength
    module Environment
      PROTOCOL_VERSION = 1
      ACTIVATION_KEY = 'FIBER_AUDIT_RUNTIME_BOOT'
      SETTINGS_KEY = 'FIBER_AUDIT_RUNTIME_SETTINGS'
      FAILURE_MODE_KEY = 'FIBER_AUDIT_RUNTIME_FAILURE_MODE'
      WATCHDOG_SETTINGS_KEY = 'FIBER_AUDIT_RUNTIME_WATCHDOG_SETTINGS'
      OPERATION_LIVENESS_SETTINGS_KEY = 'FIBER_AUDIT_RUNTIME_OPERATION_LIVENESS_SETTINGS'
      SYNCHRONIZATION_GRAPH_SETTINGS_KEY = 'FIBER_AUDIT_RUNTIME_SYNCHRONIZATION_GRAPH_SETTINGS'
      PROCESS_PROGRESS_SETTINGS_KEY = 'FIBER_AUDIT_RUNTIME_PROCESS_PROGRESS_SETTINGS'
      PROCESS_PROGRESS_WRITER_FD_KEY = 'FIBER_AUDIT_RUNTIME_PROCESS_PROGRESS_WRITER_FD'
      MAX_PROCESS_PROGRESS_SETTINGS_BYTES = 1_024
      MAX_INHERITED_FD = 1_048_575
      PROBES_KEY = 'FIBER_AUDIT_RUNTIME_PROBES'
      BOOT_REQUIRE = '-rfiber_audit/runtime/boot'
      MAX_SETTINGS_BYTES = 16_384
      MAX_WATCHDOG_SETTINGS_BYTES = 1_024
      MAX_OPERATION_LIVENESS_SETTINGS_BYTES = 1_024
      MAX_SYNCHRONIZATION_GRAPH_SETTINGS_BYTES = 1_024
      SETTINGS_KEYS = %w[protocol_version launch_id project_root output_directory policy].freeze
      POLICY_KEYS = %w[
        redaction sampling_rate max_events_per_second max_events_per_session
        max_record_bytes max_session_bytes fail_open
      ].freeze
      WATCHDOG_KEYS = %w[
        protocol_version enabled heartbeat_interval_ms stall_threshold_ms max_frames
      ].freeze
      OPERATION_LIVENESS_KEYS = %w[
        protocol_version enabled poll_interval_ms long_active_threshold_ms
      ].freeze
      SYNCHRONIZATION_GRAPH_KEYS = %w[
        protocol_version enabled max_identities max_resources max_wait_edges max_cycle_depth
      ].freeze
      PROCESS_PROGRESS_KEYS = %w[
        protocol_version enabled heartbeat_interval_ms stall_threshold_ms max_processes max_frames_per_poll max_buffer_bytes
      ].freeze

      Settings = Data.define(:protocol_version, :launch_id, :project_root, :output_directory, :policy) do
        def initialize(protocol_version:, launch_id:, project_root:, output_directory:, policy:)
          unless protocol_version == PROTOCOL_VERSION
            raise RuntimeContractError, "runtime activation protocol must be #{PROTOCOL_VERSION}"
          end
          unless launch_id.is_a?(String) && launch_id.match?(Validation::UUID)
            raise RuntimeContractError, 'runtime launch_id must be a canonical lowercase UUID'
          end
          unless policy.is_a?(Policy)
            raise RuntimeContractError, 'runtime activation policy must be a FiberAudit::Runtime::Policy'
          end

          super(
            protocol_version: protocol_version,
            launch_id: launch_id.dup.freeze,
            project_root: Environment.normalize_directory(project_root, 'project_root'),
            output_directory: Environment.normalize_directory(output_directory, 'output_directory'),
            policy: policy
          )
        end
      end

      module_function

      def build(policy:, output_directory:, project_root:, launch_id: SecureRandom.uuid)
        Settings.new(
          protocol_version: PROTOCOL_VERSION,
          launch_id: launch_id,
          project_root: project_root,
          output_directory: output_directory,
          policy: policy
        )
      end

      def dump(settings)
        require_settings!(settings)
        payload = {
          'protocol_version' => settings.protocol_version,
          'launch_id' => settings.launch_id,
          'project_root' => settings.project_root,
          'output_directory' => settings.output_directory,
          'policy' => policy_payload(settings.policy)
        }
        encoded = JSON.generate(payload)
        raise RuntimeSafetyError, 'runtime activation settings are too large' if encoded.bytesize > MAX_SETTINGS_BYTES

        encoded.freeze
      end

      def load(environment = ENV)
        return unless activated?(environment)

        value = environment.fetch(SETTINGS_KEY) do
          raise RuntimeContractError, "missing runtime activation variable: #{SETTINGS_KEY}"
        end
        unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_SETTINGS_BYTES
          raise RuntimeContractError, 'runtime activation settings are invalid'
        end

        payload = JSON.parse(value)
        require_exact_keys!(payload, SETTINGS_KEYS, 'runtime activation settings')
        policy_values = payload.fetch('policy')
        require_exact_keys!(policy_values, POLICY_KEYS, 'runtime activation policy')
        settings = Settings.new(
          protocol_version: payload.fetch('protocol_version'),
          launch_id: payload.fetch('launch_id'),
          project_root: payload.fetch('project_root'),
          output_directory: payload.fetch('output_directory'),
          policy: Policy.new(**symbolize_policy(policy_values))
        )
        validate_failure_mode!(environment, settings.policy)
        settings
      rescue JSON::ParserError, ArgumentError => e
        raise RuntimeContractError, "invalid runtime activation settings: #{e.message}"
      end

      def dump_synchronization_graph_policy(policy)
        require_synchronization_graph_policy!(policy)
        payload = { 'protocol_version' => PROTOCOL_VERSION }.merge(policy.to_h.transform_keys(&:to_s))
        encoded = JSON.generate(payload)
        if encoded.bytesize > MAX_SYNCHRONIZATION_GRAPH_SETTINGS_BYTES
          raise RuntimeSafetyError,
                'runtime synchronization-graph activation settings are too large'
        end

        encoded.freeze
      end

      def load_synchronization_graph_policy(environment = ENV)
        value = environment[SYNCHRONIZATION_GRAPH_SETTINGS_KEY]
        return SynchronizationGraphPolicy::DISABLED if value.nil?
        unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_SYNCHRONIZATION_GRAPH_SETTINGS_BYTES
          raise RuntimeContractError, 'runtime synchronization-graph activation settings are invalid'
        end

        payload = JSON.parse(value)
        require_exact_keys!(payload, SYNCHRONIZATION_GRAPH_KEYS, 'runtime synchronization-graph activation settings')
        unless payload.fetch('protocol_version') == PROTOCOL_VERSION
          raise RuntimeContractError,
                "runtime synchronization-graph activation protocol must be #{PROTOCOL_VERSION}"
        end

        SynchronizationGraphPolicy.new(**payload.except('protocol_version').transform_keys(&:to_sym))
      rescue JSON::ParserError, ArgumentError => e
        raise RuntimeContractError, "invalid runtime synchronization-graph activation settings: #{e.message}"
      end

      def dump_process_progress_policy(policy)
        require_process_progress_policy!(policy)
        payload = { 'protocol_version' => PROTOCOL_VERSION }.merge(policy.to_h.transform_keys(&:to_s))
        encoded = JSON.generate(payload)
        if encoded.bytesize > MAX_PROCESS_PROGRESS_SETTINGS_BYTES
          raise RuntimeSafetyError,
                'runtime process-progress activation settings are too large'
        end

        encoded.freeze
      end

      def load_process_progress_policy(environment = ENV)
        value = environment[PROCESS_PROGRESS_SETTINGS_KEY]
        return ProcessProgressPolicy::DISABLED if value.nil?
        unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_PROCESS_PROGRESS_SETTINGS_BYTES
          raise RuntimeContractError, 'runtime process-progress activation settings are invalid'
        end

        payload = JSON.parse(value)
        require_exact_keys!(payload, PROCESS_PROGRESS_KEYS, 'runtime process-progress activation settings')
        unless payload.fetch('protocol_version') == PROTOCOL_VERSION
          raise RuntimeContractError,
                "runtime process-progress activation protocol must be #{PROTOCOL_VERSION}"
        end

        ProcessProgressPolicy.new(**payload.except('protocol_version').transform_keys(&:to_sym))
      rescue JSON::ParserError, ArgumentError => e
        raise RuntimeContractError, "invalid runtime process-progress activation settings: #{e.message}"
      end

      def process_progress_writer_fd(environment = ENV)
        value = environment[PROCESS_PROGRESS_WRITER_FD_KEY]
        return if value.nil?
        unless value.is_a?(String) && value.match?(/\A[0-9]{1,7}\z/)
          raise RuntimeContractError,
                'runtime process-progress writer descriptor is invalid'
        end

        descriptor = Integer(value, 10)
        raise RuntimeContractError, 'runtime process-progress writer descriptor is out of range' unless descriptor.between?(
          3, MAX_INHERITED_FD
        )

        descriptor
      rescue ArgumentError
        raise RuntimeContractError, 'runtime process-progress writer descriptor is invalid'
      end

      def dump_watchdog_policy(policy)
        require_watchdog_policy!(policy)
        payload = {
          'protocol_version' => PROTOCOL_VERSION,
          'enabled' => policy.enabled,
          'heartbeat_interval_ms' => policy.heartbeat_interval_ms,
          'stall_threshold_ms' => policy.stall_threshold_ms,
          'max_frames' => policy.max_frames
        }
        encoded = JSON.generate(payload)
        if encoded.bytesize > MAX_WATCHDOG_SETTINGS_BYTES
          raise RuntimeSafetyError, 'runtime watchdog activation settings are too large'
        end

        encoded.freeze
      end

      def load_watchdog_policy(environment = ENV)
        value = environment[WATCHDOG_SETTINGS_KEY]
        return WatchdogPolicy::DISABLED if value.nil?
        unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_WATCHDOG_SETTINGS_BYTES
          raise RuntimeContractError, 'runtime watchdog activation settings are invalid'
        end

        payload = JSON.parse(value)
        require_exact_keys!(payload, WATCHDOG_KEYS, 'runtime watchdog activation settings')
        unless payload.fetch('protocol_version') == PROTOCOL_VERSION
          raise RuntimeContractError, "runtime watchdog activation protocol must be #{PROTOCOL_VERSION}"
        end

        WatchdogPolicy.new(
          enabled: payload.fetch('enabled'),
          heartbeat_interval_ms: payload.fetch('heartbeat_interval_ms'),
          stall_threshold_ms: payload.fetch('stall_threshold_ms'),
          max_frames: payload.fetch('max_frames')
        )
      rescue JSON::ParserError, ArgumentError => e
        raise RuntimeContractError, "invalid runtime watchdog activation settings: #{e.message}"
      end

      def dump_operation_liveness_policy(policy)
        require_operation_liveness_policy!(policy)
        payload = {
          'protocol_version' => PROTOCOL_VERSION,
          'enabled' => policy.enabled,
          'poll_interval_ms' => policy.poll_interval_ms,
          'long_active_threshold_ms' => policy.long_active_threshold_ms
        }
        encoded = JSON.generate(payload)
        if encoded.bytesize > MAX_OPERATION_LIVENESS_SETTINGS_BYTES
          raise RuntimeSafetyError, 'runtime operation-liveness activation settings are too large'
        end

        encoded.freeze
      end

      def load_operation_liveness_policy(environment = ENV)
        value = environment[OPERATION_LIVENESS_SETTINGS_KEY]
        return OperationLivenessPolicy::DISABLED if value.nil?
        unless value.is_a?(String) && value.valid_encoding? &&
               value.bytesize <= MAX_OPERATION_LIVENESS_SETTINGS_BYTES
          raise RuntimeContractError, 'runtime operation-liveness activation settings are invalid'
        end

        payload = JSON.parse(value)
        require_exact_keys!(payload, OPERATION_LIVENESS_KEYS, 'runtime operation-liveness activation settings')
        unless payload.fetch('protocol_version') == PROTOCOL_VERSION
          raise RuntimeContractError, "runtime operation-liveness activation protocol must be #{PROTOCOL_VERSION}"
        end

        OperationLivenessPolicy.new(
          enabled: payload.fetch('enabled'),
          poll_interval_ms: payload.fetch('poll_interval_ms'),
          long_active_threshold_ms: payload.fetch('long_active_threshold_ms')
        )
      rescue JSON::ParserError, ArgumentError => e
        raise RuntimeContractError, "invalid runtime operation-liveness activation settings: #{e.message}"
      end

      def activated?(environment = ENV)
        marker = environment[ACTIVATION_KEY]
        return false if marker.nil?
        return true if marker == '1'

        raise RuntimeContractError, "#{ACTIVATION_KEY} must be 1"
      end

      def failure_mode(environment = ENV)
        value = environment[FAILURE_MODE_KEY]
        return :open if value.nil? || value == 'open'
        return :closed if value == 'closed'

        raise RuntimeContractError, "#{FAILURE_MODE_KEY} must be open or closed"
      end

      def probes_enabled?(environment = ENV)
        value = environment[PROBES_KEY]
        return false if value.nil?
        return true if value == '1'

        raise RuntimeContractError, "#{PROBES_KEY} must be 1 when present"
      end

      # Keep child activation serialization together at this environment boundary.
      # rubocop:disable Metrics/AbcSize
      def child_environment(
        settings:,
        watchdog_policy: nil,
        operation_liveness_policy: nil,
        synchronization_graph_policy: nil,
        process_progress_policy: nil,
        process_progress_writer_fd: nil,
        probes_enabled: false,
        base_environment: ENV,
        library_path: default_library_path
      )
        require_settings!(settings)
        require_watchdog_policy!(watchdog_policy) if watchdog_policy
        require_operation_liveness_policy!(operation_liveness_policy) if operation_liveness_policy
        require_synchronization_graph_policy!(synchronization_graph_policy) if synchronization_graph_policy
        require_process_progress_policy!(process_progress_policy) if process_progress_policy
        validate_process_progress_transport!(process_progress_policy, process_progress_writer_fd)
        raise RuntimeContractError, 'probes_enabled must be a Boolean' unless [true, false].include?(probes_enabled)
        raise RuntimeContractError, 'base_environment must be a Hash-like object' unless base_environment.respond_to?(:[])

        environment = {
          ACTIVATION_KEY => '1',
          SETTINGS_KEY => dump(settings),
          FAILURE_MODE_KEY => settings.policy.fail_open? ? 'open' : 'closed',
          'RUBYOPT' => prepend_token(base_environment['RUBYOPT'], BOOT_REQUIRE, separator: ' '),
          'RUBYLIB' => prepend_token(base_environment['RUBYLIB'], library_path, separator: File::PATH_SEPARATOR)
        }
        environment[WATCHDOG_SETTINGS_KEY] = dump_watchdog_policy(watchdog_policy) if watchdog_policy
        if operation_liveness_policy
          environment[OPERATION_LIVENESS_SETTINGS_KEY] = dump_operation_liveness_policy(operation_liveness_policy)
        end
        if synchronization_graph_policy
          environment[SYNCHRONIZATION_GRAPH_SETTINGS_KEY] = dump_synchronization_graph_policy(synchronization_graph_policy)
        end
        if process_progress_policy
          environment[PROCESS_PROGRESS_SETTINGS_KEY] =
            dump_process_progress_policy(process_progress_policy)
        end
        environment[PROCESS_PROGRESS_WRITER_FD_KEY] = process_progress_writer_fd.to_s.freeze if process_progress_writer_fd
        environment[PROBES_KEY] = '1' if probes_enabled
        environment.transform_values(&:freeze).freeze
      end
      # rubocop:enable Metrics/AbcSize

      def prepare_output_directory(path)
        normalized = normalize_absolute_path(path, 'output directory')
        if File.exist?(normalized)
          raise RuntimeSafetyError, "runtime output is not a directory: #{normalized}" unless File.directory?(normalized)

          return normalized
        end

        FileUtils.mkdir_p(normalized, mode: 0o700)
        File.chmod(0o700, normalized)
        normalized
      rescue SystemCallError => e
        raise RuntimeSafetyError, "cannot prepare runtime output directory: #{e.message}"
      end

      def normalize_directory(value, field)
        normalized = normalize_absolute_path(value, field)
        raise RuntimeContractError, "#{field} must be an existing directory" unless File.directory?(normalized)

        normalized.freeze
      end

      def default_library_path
        File.expand_path('../..', __dir__).freeze
      end
      private_class_method :default_library_path

      def normalize_absolute_path(value, field)
        text = Validation.string(value, field, max_bytes: 4_096)
        path = Pathname.new(text)
        raise RuntimeContractError, "#{field} must be absolute" unless path.absolute?

        path.cleanpath.to_s.freeze
      rescue ArgumentError
        raise RuntimeContractError, "#{field} is invalid"
      end
      private_class_method :normalize_absolute_path

      def prepend_token(existing, token, separator:)
        current = existing.to_s
        parts = current.split(separator)
        return current.dup.freeze if parts.include?(token)

        current.empty? ? token.dup.freeze : "#{token}#{separator}#{current}".freeze
      end
      private_class_method :prepend_token

      def require_settings!(value)
        return if value.is_a?(Settings)

        raise RuntimeContractError, 'settings must be FiberAudit::Runtime::Environment::Settings'
      end
      private_class_method :require_settings!

      def require_watchdog_policy!(value)
        return if value.is_a?(WatchdogPolicy)

        raise RuntimeContractError, 'watchdog_policy must be FiberAudit::Runtime::WatchdogPolicy'
      end
      private_class_method :require_watchdog_policy!

      def require_process_progress_policy!(value)
        return if value.is_a?(ProcessProgressPolicy)

        raise RuntimeContractError, 'process_progress_policy must be FiberAudit::Runtime::ProcessProgressPolicy'
      end
      private_class_method :require_process_progress_policy!

      def validate_process_progress_transport!(policy, descriptor)
        process_progress_writer_fd(PROCESS_PROGRESS_WRITER_FD_KEY => descriptor.to_s) if descriptor
        if policy&.enabled? && descriptor.nil?
          raise RuntimeContractError,
                'enabled process progress requires an inherited writer descriptor'
        end
        return unless descriptor && !policy&.enabled?

        raise RuntimeContractError,
              'process progress writer descriptor requires an enabled policy'
      end
      private_class_method :validate_process_progress_transport!

      def attach_process_progress_transport(environment, policy:, writer_fd:)
        raise RuntimeContractError, 'child environment must be a Hash' unless environment.is_a?(Hash)

        require_process_progress_policy!(policy)
        raise RuntimeContractError, 'process progress transport requires an enabled policy' unless policy.enabled?
        if environment.key?(PROCESS_PROGRESS_SETTINGS_KEY) || environment.key?(PROCESS_PROGRESS_WRITER_FD_KEY)
          raise RuntimeContractError, 'child environment already contains process progress transport'
        end

        descriptor = process_progress_writer_fd(PROCESS_PROGRESS_WRITER_FD_KEY => writer_fd.to_s)
        environment.merge(PROCESS_PROGRESS_SETTINGS_KEY => dump_process_progress_policy(policy),
                          PROCESS_PROGRESS_WRITER_FD_KEY => descriptor.to_s.freeze).transform_values do |value|
          value&.dup&.freeze
        end.freeze
      end

      def open_process_progress_writer(environment = ENV)
        descriptor = process_progress_writer_fd(environment)
        return if descriptor.nil?

        writer = IO.for_fd(descriptor, 'wb', autoclose: true)
        writer.binmode
        writer.sync = true
        writer
      rescue SystemCallError, IOError, ArgumentError => e
        raise RuntimeContractError, "cannot open process progress writer descriptor: #{e.class}"
      end

      def require_synchronization_graph_policy!(value)
        return if value.is_a?(SynchronizationGraphPolicy)

        raise RuntimeContractError, 'synchronization_graph_policy must be FiberAudit::Runtime::SynchronizationGraphPolicy'
      end
      private_class_method :require_synchronization_graph_policy!

      def require_operation_liveness_policy!(value)
        return if value.is_a?(OperationLivenessPolicy)

        raise RuntimeContractError,
              'operation_liveness_policy must be FiberAudit::Runtime::OperationLivenessPolicy'
      end
      private_class_method :require_operation_liveness_policy!

      def require_exact_keys!(value, expected, path)
        raise RuntimeContractError, "#{path} must be an object" unless value.is_a?(Hash)

        unknown = value.keys - expected
        missing = expected - value.keys
        raise RuntimeContractError, "unknown key #{unknown.first} at #{path}" unless unknown.empty?
        raise RuntimeContractError, "missing key #{missing.first} at #{path}" unless missing.empty?
      end
      private_class_method :require_exact_keys!

      def policy_payload(policy)
        policy.to_h.transform_values { |value| value.is_a?(Symbol) ? value.to_s : value }.transform_keys(&:to_s)
      end
      private_class_method :policy_payload

      def symbolize_policy(values)
        values.to_h { |key, value| [key.to_sym, value] }
      end
      private_class_method :symbolize_policy

      def validate_failure_mode!(environment, policy)
        expected = policy.fail_open? ? :open : :closed
        actual = failure_mode(environment)
        return if actual == expected

        raise RuntimeContractError, 'runtime activation failure mode does not match policy'
      end
      private_class_method :validate_failure_mode!
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
