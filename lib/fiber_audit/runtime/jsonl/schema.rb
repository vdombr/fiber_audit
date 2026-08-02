# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../../errors'
require_relative '../event'
require_relative '../session'

module FiberAudit
  module Runtime
    module JSONL
      # Versioned builders and validators stay together to keep one schema authority.
      # rubocop:disable Metrics/ModuleLength
      module Schema
        SCHEMA_VERSION = '1.0'
        RECORD_TYPES = %w[session_start event session_end].freeze
        ENVELOPE_KEYS = %w[
          schema_version record_type session_id sequence recorded_at monotonic_ns payload
        ].freeze
        POLICY_KEYS = %w[
          redaction sampling_rate max_events_per_second max_events_per_session
          max_record_bytes max_session_bytes fail_open
        ].freeze
        EVENT_KEYS = %w[
          kind source duration_ns operation location execution_context thread_id fiber_id measurements
        ].freeze
        LOCATION_KEYS = %w[path line column].freeze
        END_KEYS = %w[status events_observed events_emitted dropped internal_errors].freeze
        DROPPED_KEYS = %w[
          sampling rate_limit session_event_limit session_byte_limit record_size_limit
        ].freeze
        UUID = Validation::UUID
        TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

        module_function

        def start_record(session)
          require_type!(session, Session, 'session')
          build_record(
            record_type: 'session_start',
            session_id: session.id,
            sequence: 0,
            recorded_at: session.started_at,
            monotonic_ns: session.started_monotonic_ns,
            payload: {
              'tool_version' => session.tool_version,
              'ruby_version' => session.ruby_version,
              'policy' => policy_payload(session.policy)
            }
          )
        end

        def event_record(session_id:, sequence:, event:)
          require_type!(event, Event, 'event')
          build_record(
            record_type: 'event',
            session_id: session_id,
            sequence: sequence,
            recorded_at: event.occurred_at,
            monotonic_ns: event.monotonic_ns,
            payload: {
              'kind' => event.kind.to_s,
              'source' => event.source.to_s,
              'duration_ns' => event.duration_ns,
              'operation' => event.operation,
              'location' => location_payload(event.location),
              'execution_context' => event.execution_context.to_s,
              'thread_id' => event.thread_id,
              'fiber_id' => event.fiber_id,
              'measurements' => event.measurements
            }
          )
        end

        def end_record(session_id:, sequence:, summary:)
          require_type!(summary, SessionSummary, 'summary')
          build_record(
            record_type: 'session_end',
            session_id: session_id,
            sequence: sequence,
            recorded_at: summary.ended_at,
            monotonic_ns: summary.ended_monotonic_ns,
            payload: {
              'status' => summary.status.to_s,
              'events_observed' => summary.events_observed,
              'events_emitted' => summary.events_emitted,
              'dropped' => {
                'sampling' => summary.sampled_out,
                'rate_limit' => summary.rate_limited,
                'session_event_limit' => summary.session_event_limited,
                'session_byte_limit' => summary.session_byte_limited,
                'record_size_limit' => summary.oversize
              },
              'internal_errors' => summary.internal_errors
            }
          )
        end

        def validate!(record)
          require_exact_keys!(record, ENVELOPE_KEYS, 'record')
          require_value!(record['schema_version'] == SCHEMA_VERSION, 'schema_version must be 1.0')
          require_value!(RECORD_TYPES.include?(record['record_type']), 'record_type is invalid')
          validate_uuid!(record['session_id'])
          validate_sequence!(record['sequence'], record['record_type'])
          parse_timestamp(record['recorded_at'], 'recorded_at')
          require_non_negative_integer!(record['monotonic_ns'], 'monotonic_ns')

          case record['record_type']
          when 'session_start' then validate_start_payload!(record['payload'])
          when 'event' then validate_event_payload!(record)
          when 'session_end' then validate_end_payload!(record)
          end

          record
        rescue RuntimeContractError
          raise
        rescue StandardError => e
          raise RuntimeContractError, "invalid runtime JSONL record: #{e.message}"
        end

        def dump(record, max_record_bytes:)
          validate!(record)
          unless max_record_bytes.is_a?(Integer) && max_record_bytes.positive?
            raise RuntimeContractError, 'max_record_bytes must be a positive Integer'
          end

          json = "#{::JSON.generate(record)}\n"
          if json.bytesize > max_record_bytes
            raise RuntimeSafetyError,
                  "runtime JSONL record is #{json.bytesize} bytes; limit is #{max_record_bytes}"
          end

          json.freeze
        rescue ::JSON::GeneratorError => e
          raise RuntimeContractError, "runtime JSONL record is not JSON-safe: #{e.message}"
        end

        def build_record(record_type:, session_id:, sequence:, recorded_at:, monotonic_ns:, payload:)
          record = {
            'schema_version' => SCHEMA_VERSION,
            'record_type' => record_type,
            'session_id' => session_id.is_a?(String) ? session_id.dup : session_id,
            'sequence' => sequence,
            'recorded_at' => format_time(recorded_at),
            'monotonic_ns' => monotonic_ns,
            'payload' => payload
          }
          validate!(record)
          deep_freeze(record)
        end
        private_class_method :build_record

        def policy_payload(policy)
          {
            'redaction' => policy.redaction.to_s,
            'sampling_rate' => policy.sampling_rate,
            'max_events_per_second' => policy.max_events_per_second,
            'max_events_per_session' => policy.max_events_per_session,
            'max_record_bytes' => policy.max_record_bytes,
            'max_session_bytes' => policy.max_session_bytes,
            'fail_open' => policy.fail_open
          }
        end
        private_class_method :policy_payload

        def location_payload(location)
          return unless location

          { 'path' => location.path, 'line' => location.line, 'column' => location.column }
        end
        private_class_method :location_payload

        def validate_start_payload!(payload)
          require_exact_keys!(payload, %w[tool_version ruby_version policy], 'session_start payload')
          Validation.string(payload['tool_version'], 'tool_version', max_bytes: 64)
          Validation.string(payload['ruby_version'], 'ruby_version', max_bytes: 64)
          require_exact_keys!(payload['policy'], POLICY_KEYS, 'policy')
          values = payload['policy']
          Policy.new(
            redaction: values['redaction'],
            sampling_rate: values['sampling_rate'],
            max_events_per_second: values['max_events_per_second'],
            max_events_per_session: values['max_events_per_session'],
            max_record_bytes: values['max_record_bytes'],
            max_session_bytes: values['max_session_bytes'],
            fail_open: values['fail_open']
          )
        end
        private_class_method :validate_start_payload!

        def validate_event_payload!(record)
          payload = record['payload']
          require_exact_keys!(payload, EVENT_KEYS, 'event payload')
          location = validate_location_payload!(payload['location'])
          Event.new(
            kind: payload['kind'],
            source: payload['source'],
            occurred_at: parse_timestamp(record['recorded_at'], 'recorded_at'),
            monotonic_ns: record['monotonic_ns'],
            duration_ns: payload['duration_ns'],
            operation: payload['operation'],
            location: location,
            execution_context: payload['execution_context'],
            thread_id: payload['thread_id'],
            fiber_id: payload['fiber_id'],
            measurements: payload['measurements']
          )
        end
        private_class_method :validate_event_payload!

        def validate_location_payload!(payload)
          return if payload.nil?

          require_exact_keys!(payload, LOCATION_KEYS, 'location')
          Location.new(path: payload['path'], line: payload['line'], column: payload['column'])
        end
        private_class_method :validate_location_payload!

        def validate_end_payload!(record)
          payload = record['payload']
          require_exact_keys!(payload, END_KEYS, 'session_end payload')
          require_exact_keys!(payload['dropped'], DROPPED_KEYS, 'dropped')
          dropped = payload['dropped']
          SessionSummary.new(
            ended_at: parse_timestamp(record['recorded_at'], 'recorded_at'),
            ended_monotonic_ns: record['monotonic_ns'],
            status: payload['status'],
            events_observed: payload['events_observed'],
            events_emitted: payload['events_emitted'],
            sampled_out: dropped['sampling'],
            rate_limited: dropped['rate_limit'],
            session_event_limited: dropped['session_event_limit'],
            session_byte_limited: dropped['session_byte_limit'],
            oversize: dropped['record_size_limit'],
            internal_errors: payload['internal_errors']
          )
        end
        private_class_method :validate_end_payload!

        def require_exact_keys!(value, expected, path)
          raise RuntimeContractError, "#{path} must be an object" unless value.is_a?(Hash)

          keys = value.keys
          unknown = keys - expected
          missing = expected - keys
          raise RuntimeContractError, "unknown key #{unknown.first.inspect} at #{path}" unless unknown.empty?
          raise RuntimeContractError, "missing key #{missing.first.inspect} at #{path}" unless missing.empty?
        end
        private_class_method :require_exact_keys!

        def validate_uuid!(value)
          require_value!(value.is_a?(String) && value.match?(UUID), 'session_id must be a canonical lowercase UUID')
        end
        private_class_method :validate_uuid!

        def validate_sequence!(value, record_type)
          minimum = record_type == 'session_start' ? 0 : 1
          require_non_negative_integer!(value, 'sequence')
          require_value!(value.zero?, 'session_start sequence must be 0') if record_type == 'session_start'
          require_value!(value >= minimum, "#{record_type} sequence must be positive") unless record_type == 'session_start'
        end
        private_class_method :validate_sequence!

        def parse_timestamp(value, field)
          require_value!(
            value.is_a?(String) && value.match?(TIMESTAMP),
            "#{field} must be UTC RFC3339 with six fractional digits"
          )
          Time.iso8601(value)
        rescue ArgumentError
          raise RuntimeContractError, "#{field} is not a valid timestamp"
        end
        private_class_method :parse_timestamp

        def format_time(value)
          Validation.utc_time(value, 'recorded_at').iso8601(6)
        end
        private_class_method :format_time

        def require_non_negative_integer!(value, field)
          require_value!(value.is_a?(Integer) && value >= 0, "#{field} must be a non-negative Integer")
        end
        private_class_method :require_non_negative_integer!

        def require_type!(value, type, field)
          raise RuntimeContractError, "#{field} must be a #{type}" unless value.is_a?(type)
        end
        private_class_method :require_type!

        def require_value!(condition, message)
          raise RuntimeContractError, message unless condition
        end
        private_class_method :require_value!

        def deep_freeze(value)
          case value
          when Hash
            value.each do |key, entry|
              deep_freeze(key)
              deep_freeze(entry)
            end
          when Array
            value.each { |entry| deep_freeze(entry) }
          end
          value.freeze
        end
        private_class_method :deep_freeze
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
