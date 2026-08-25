# frozen_string_literal: true

module FiberAudit
  module Runtime
    module ProcessProgressProtocol
      MAGIC = 'FAPG'.b.freeze
      VERSION = 1
      KIND_PROGRESS = 1
      RESERVED = 0
      PACK_DIRECTIVE = 'a4CCnQ>Q>Q>Q>'
      FRAME_BYTES = 40
      MAX_UINT64 = (2**64) - 1

      Frame = Data.define(:pid, :generation, :sequence, :monotonic_ns)
      DecodeResult = Data.define(:frames, :malformed_frames, :truncated) do
        def initialize(frames:, malformed_frames:, truncated:)
          super(frames: frames.dup.freeze, malformed_frames: malformed_frames, truncated: truncated)
        end

        def truncated? = truncated
      end

      class Decoder
        attr_reader :max_buffer_bytes

        def initialize(max_buffer_bytes:)
          unless max_buffer_bytes.is_a?(Integer) && max_buffer_bytes >= FRAME_BYTES * 2
            raise RuntimeContractError, "max_buffer_bytes must be an Integer of at least #{FRAME_BYTES * 2}"
          end

          @max_buffer_bytes = max_buffer_bytes
          @buffer = +''.b
        end

        def feed(bytes, max_frames:)
          unless bytes.is_a?(String) && bytes.valid_encoding?
            raise RuntimeContractError,
                  'process progress bytes must be a valid String'
          end
          unless max_frames.is_a?(Integer) && max_frames.positive?
            raise RuntimeContractError,
                  'max_frames must be a positive Integer'
          end

          truncated = append_bounded(bytes.b)
          frames = []
          malformed = 0
          while @buffer.bytesize >= FRAME_BYTES && frames.size < max_frames
            unless @buffer.start_with?(MAGIC)
              discard = resynchronization_offset
              @buffer.slice!(0, discard)
              malformed += 1
              next
            end
            candidate = @buffer.slice!(0, FRAME_BYTES)
            frame = ProcessProgressProtocol.decode(candidate)
            if frame
              frames << frame
            else
              malformed += 1
            end
          end
          DecodeResult.new(frames: frames, malformed_frames: malformed, truncated: truncated)
        end

        def buffered_bytes = @buffer.bytesize

        private

        # The action returns whether truncation occurred; it is not a query API.
        # rubocop:disable Naming/PredicateMethod
        def append_bounded(bytes)
          return false if bytes.empty?

          if bytes.bytesize > max_buffer_bytes
            @buffer.replace(bytes.byteslice(-max_buffer_bytes, max_buffer_bytes))
            return true
          end
          overflow = @buffer.bytesize + bytes.bytesize - max_buffer_bytes
          @buffer.slice!(0, overflow) if overflow.positive?
          @buffer << bytes
          overflow.positive?
        end
        # rubocop:enable Naming/PredicateMethod

        def resynchronization_offset
          found = @buffer.index(MAGIC, 1)
          found || [@buffer.bytesize - (MAGIC.bytesize - 1), 1].max
        end
      end

      module_function

      def encode(pid:, generation:, sequence:, monotonic_ns:)
        values = { pid: pid, generation: generation, sequence: sequence, monotonic_ns: monotonic_ns }
        values.each { |name, value| validate_uint64!(value, name) }
        [MAGIC, VERSION, KIND_PROGRESS, RESERVED, values[:pid], values[:generation], values[:sequence],
         values[:monotonic_ns]].pack(PACK_DIRECTIVE).freeze
      end

      def decode(bytes)
        return unless bytes.is_a?(String) && bytes.bytesize == FRAME_BYTES

        magic, version, kind, reserved, pid, generation, sequence, monotonic_ns = bytes.unpack(PACK_DIRECTIVE)
        return unless magic == MAGIC && version == VERSION && kind == KIND_PROGRESS && reserved == RESERVED

        Frame.new(
          pid: validate_uint64!(pid, :pid), generation: validate_uint64!(generation, :generation),
          sequence: validate_uint64!(sequence, :sequence),
          monotonic_ns: validate_uint64!(monotonic_ns, :monotonic_ns)
        )
      rescue StandardError
        nil
      end

      def validate_uint64!(value, field)
        unless value.is_a?(Integer) && value.between?(
          1, MAX_UINT64
        )
          raise RuntimeContractError,
                "#{field} must be an Integer in 1..#{MAX_UINT64}"
        end

        value
      end
      private_class_method :validate_uint64!
    end
  end
end
