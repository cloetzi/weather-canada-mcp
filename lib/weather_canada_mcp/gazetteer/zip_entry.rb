# frozen_string_literal: true

require "zlib"

module WeatherCanadaMcp
  class Gazetteer
    # Reads one stored or deflated member of a ZIP archive held in memory, without a zip gem. Locates the member
    # through the central directory (local headers may defer sizes to a data descriptor) and inflates it in chunks,
    # refusing to produce more than max_bytes.
    class ZipEntry
      EOCD_SIGNATURE = "PK\x05\x06".b
      CENTRAL_SIGNATURE = 0x02014b50
      LOCAL_SIGNATURE = 0x04034b50
      CHUNK = 1 << 16

      def self.first(archive, suffix:, max_bytes:, &) = new(archive).first(suffix:, max_bytes:, &)

      def initialize(archive)
        @archive = archive.encoding == Encoding::BINARY ? archive : archive.b
      end

      # Yields the decompressed bytes of the first member whose name ends with suffix, chunk by chunk.
      def first(suffix:, max_bytes:, &block)
        return enum_for(:first, suffix:, max_bytes:) unless block

        entry = entries.find { |candidate| candidate[:name].end_with?(suffix) } or raise Error, "the archive has no #{suffix} file"
        extract(entry, max_bytes, &block)
      end

      private

      def entries
        eocd = @archive.rindex(EOCD_SIGNATURE) or raise Error, "not a ZIP archive"
        count, _size, offset = slice(eocd + 10, 10).unpack("vVV")
        Array.new(count) do
          signature, method, compressed, name_length, extra_length, comment_length, local =
            slice(offset, 46).unpack("V x6 v x8 V x4 v v v x8 V")
          raise Error, "corrupt ZIP central directory" unless signature == CENTRAL_SIGNATURE

          name = slice(offset + 46, name_length).dup.force_encoding(Encoding::UTF_8)
          offset += 46 + name_length + extra_length + comment_length
          { name:, method:, compressed:, local: }
        end
      end

      def extract(entry, max_bytes, &)
        signature, name_length, extra_length = slice(entry[:local], 30).unpack("V x22 v v")
        raise Error, "corrupt ZIP local header" unless signature == LOCAL_SIGNATURE

        start = entry[:local] + 30 + name_length + extra_length
        data = slice(start, entry[:compressed])

        case entry[:method]
        when 0 then emit(data, max_bytes, 0, &)
        when 8 then inflate(data, max_bytes, &)
        else raise Error, "unsupported ZIP compression method #{entry[:method]}"
        end
      end

      # Raises instead of returning a short or nil slice, so truncated archives fail with a clear error.
      def slice(offset, length)
        data = @archive.byteslice(offset, length) if offset && length && offset >= 0
        raise Error, "truncated or corrupt ZIP archive" unless data&.bytesize == length

        data
      end

      def inflate(data, max_bytes, &)
        inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
        produced = 0
        (0...data.bytesize).step(CHUNK) do |position|
          produced = emit(inflater.inflate(data.byteslice(position, CHUNK)), max_bytes, produced, &)
        end
        produced = emit(inflater.finish, max_bytes, produced, &)
        produced
      rescue Zlib::Error => e
        raise Error, "corrupt ZIP data (#{e.class})"
      ensure
        inflater&.close
      end

      def emit(chunk, max_bytes, produced)
        produced += chunk.bytesize
        raise Error, "the archive member is larger than #{max_bytes} bytes" if produced > max_bytes

        yield chunk unless chunk.empty?
        produced
      end
    end
  end
end
