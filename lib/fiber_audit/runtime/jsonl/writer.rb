# frozen_string_literal: true

require_relative '../../errors'
require_relative '../validation'
require_relative 'schema'

module FiberAudit
  module Runtime
    module JSONL
      class Writer
        attr_reader :bytes_written, :max_record_bytes

        def self.open(path:, max_record_bytes:)
          safe_path = Validation.string(path, 'runtime output path', max_bytes: 4_096)
          # The returned Writer deliberately owns this descriptor until #close.
          io = File.open(safe_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) # rubocop:disable Style/FileOpen
          io.binmode
          io.sync = true
          new(io: io, max_record_bytes: max_record_bytes, owns_io: true)
        rescue StandardError
          io&.close
          raise
        end

        def initialize(io:, max_record_bytes:, owns_io: false)
          raise RuntimeContractError, 'io must respond to write' unless io.respond_to?(:write)
          unless max_record_bytes.is_a?(Integer) && max_record_bytes.positive?
            raise RuntimeContractError, 'max_record_bytes must be a positive Integer'
          end
          raise RuntimeContractError, 'owns_io must be a Boolean' unless [true, false].include?(owns_io)

          @io = io
          @max_record_bytes = max_record_bytes
          @owns_io = owns_io
          @bytes_written = 0
          @state = :active
        end

        def prepare(record)
          ensure_active!
          Schema.dump(record, max_record_bytes: max_record_bytes)
        end

        def write(record)
          write_line(prepare(record))
        end

        def write_line(line)
          ensure_active!
          validate_line!(line)
          completed = false
          begin
            write_all(line)
            @io.flush if @io.respond_to?(:flush)
            completed = true
          ensure
            @state = :failed unless completed
          end
          line.bytesize
        end

        def active?
          @state == :active
        end

        def failed?
          @state == :failed
        end

        def closed?
          @state == :closed
        end

        def close
          return if closed?

          completed = false
          begin
            @io.close if @owns_io && @io.respond_to?(:close) && !@io.closed?
            completed = true
          ensure
            @state = :failed unless completed
          end
          @state = :closed unless failed?
          nil
        end

        private

        def write_all(line)
          offset = 0
          while offset < line.bytesize
            written = @io.write(line.byteslice(offset, line.bytesize - offset))
            validate_write_result!(written, line.bytesize - offset)
            offset += written
            @bytes_written += written
          end
        end

        def ensure_active!
          raise RuntimeSafetyError, "runtime JSONL writer is #{@state}" unless active?
        end

        def validate_line!(line)
          valid = line.is_a?(String) && line.valid_encoding? && line.end_with?("\n") && line.count("\n") == 1
          raise RuntimeContractError, 'runtime JSONL line must be one valid complete line' unless valid
          return unless line.bytesize > max_record_bytes

          raise RuntimeSafetyError,
                "runtime JSONL record is #{line.bytesize} bytes; limit is #{max_record_bytes}"
        end

        def validate_write_result!(written, remaining)
          return if written.is_a?(Integer) && written.positive? && written <= remaining

          @state = :failed
          raise RuntimeSafetyError, "runtime JSONL write returned invalid byte count: #{written.inspect}"
        end
      end
    end
  end
end
