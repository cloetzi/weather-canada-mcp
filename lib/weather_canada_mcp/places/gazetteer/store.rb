# frozen_string_literal: true

require "async/promise"
require "fileutils"
require "stringio"
require "zip"
require "zlib"

module WeatherCanadaMCP
  module Places
    class Gazetteer
      # Opens the gazetteer, building it on first use when the database is missing and auto_build is on: downloads the
      # CGN archive (~16 MB) through the upstream client, then inflates and loads it in background threads (streamed
      # through a pipe), so the reactor keeps serving other requests. Concurrent callers share one build. A failed
      # build is not retried for RETRY_AFTER seconds, so a broken setup does not re-download the archive on every call.
      #
      # warm_up! (the stdio server, at startup) starts the build at once and makes lookups refuse with Preparing while it
      # runs, because a person waiting in a chat should not sit through the download inside one tool call.
      class Store
        CGN_PATH = "/pub/nrcan_rncan/vector/geobase_cgn_toponyme/prov_csv_eng/cgn_canada_csv_eng.zip"
        MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
        MAX_CSV_BYTES = 512 * 1024 * 1024
        CHUNK_BYTES = 64 * 1024
        DOWNLOAD_TIMEOUT = 300
        RETRY_AFTER = 600

        def initialize(path:, http:, logger:, auto_build: true, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @path = path
          @http = http
          @logger = logger
          @auto_build = auto_build
          @clock = clock
          @gazetteer = nil
          @building = nil
          @failure = nil
          @warming = false
        end

        attr_reader :path

        def available? = !@gazetteer.nil? || File.file?(@path)

        def open
          return @gazetteer if @gazetteer

          opened = open_or_build
          # Another fiber may have opened it while this one waited for the build.
          return opened.tap { @gazetteer = opened } unless @gazetteer

          opened.close
          @gazetteer
        end

        # Starts building the database in the background when it is missing and auto_build is on. Needs the reactor.
        def warm_up!
          return if @gazetteer || @building || !@auto_build || File.file?(@path)

          @warming = true
          start_build
        rescue Unavailable
          nil # a recent failure is reported by the lookups
        end

        # Downloads and rebuilds unconditionally (the `gazetteer update` command), then reopens.
        def rebuild!
          build
          @gazetteer&.close
          @gazetteer = Gazetteer.new(@path)
        end

        def close = @gazetteer&.close

        private

        def open_or_build
          return Gazetteer.new(@path) if File.file?(@path)
          raise Unavailable, "the place-name database is not installed (run `weather-canada-mcp gazetteer update`)" unless @auto_build

          if @warming
            start_build unless @building
            raise Preparing, "the place-name database is being built"
          end

          (@building || start_build).wait
          Gazetteer.new(@path)
        end

        # The build runs as a task of its own, so a caller that gives up (its tool call ran out of time) does not stop it
        # halfway: the archive takes longer to download than a tool call may run, and the next call finds it done.
        def start_build
          if @failure && @clock.call - @failure[:at] < RETRY_AFTER
            raise Unavailable, "#{@failure[:message]} (not retried for #{RETRY_AFTER / 60} minutes)"
          end

          @building = Async::Promise.new
          scheduler = Fiber.scheduler
          scheduler ? scheduler.async { build_once(@building) } : build_once(@building)
          @building
        end

        def build_once(promise)
          build
          @failure = nil
          promise.resolve(true)
        rescue Unavailable => e
          @failure = { at: @clock.call, message: e.message }
          promise.reject(e)
        ensure
          promise.reject(Unavailable.new("the place-name build was cancelled")) unless promise.resolved?
          @building = nil
        end

        def build
          @logger.info("gazetteer_download", path: @path, message: "downloading Canadian Geographical Names (one time)")
          response = @http.get(:cgn, CGN_PATH, accept: "application/zip", max_body_bytes: MAX_ARCHIVE_BYTES, timeout: DOWNLOAD_TIMEOUT)
          raise Sources::StatusError.new(response.status, "ftp.maps.canada.ca") unless response.success?

          load(response.body)
        rescue Sources::Error, BuildError, SystemCallError, SQLite3::Exception => e
          raise Unavailable, "the place-name database could not be built: #{e.message}"
        rescue StandardError => e # malformed CSV, text or ZIP: the class says enough, the message could quote the data
          raise Unavailable, "the place-name database could not be built: the NRCan data could not be read (#{e.class})"
        end

        # The inflater writes the CSV into a pipe that the builder reads, so the whole CSV is never held in memory. The
        # builder writes a staging file that is moved into place only once the inflater has also finished cleanly, so a
        # CSV that was cut off or failed its checksum is never installed.
        def load(archive)
          staging = "#{@path}.#{Process.pid}.staging"
          reader, writer = IO.pipe
          reader.set_encoding("BOM|UTF-8")
          inflater = thread { inflate(archive, writer) }
          builder = thread { Builder.new(logger: @logger).build(reader, staging, source: "https://ftp.maps.canada.ca#{CGN_PATH}") }
          count = finish(builder, inflater, reader)
          File.rename(staging, @path)
          count
        ensure
          FileUtils.rm_f(staging) if staging
          reader&.close # an early builder failure makes the inflater's next write fail instead of block
          inflater&.join
        end

        # When both fail, the inflater's error is the cause (the builder only saw the stream end).
        def finish(builder, inflater, reader)
          count = builder.value
          inflater.value
          count
        rescue StandardError
          reader.close
          inflater.value
          raise
        end

        # The archive comes from the network, so the CSV is held to the size its directory declares, which is itself
        # capped, and to its checksum: rubyzip checks neither while streaming.
        def inflate(archive, writer)
          entry = csv_entry(archive)
          entry.get_input_stream { |stream| copy(stream, writer, entry) }
        ensure
          writer.close
        end

        def copy(stream, writer, entry)
          total = 0
          crc = Zlib.crc32
          while (chunk = stream.read(CHUNK_BYTES))
            total += chunk.bytesize
            raise BuildError, "the CGN CSV is longer than its archive declares" if total > entry.size

            crc = Zlib.crc32(chunk, crc)
            return unless write(writer, chunk)
          end
          raise BuildError, "the CGN CSV is shorter than its archive declares" if total < entry.size
          raise BuildError, "the CGN CSV failed its checksum" unless crc == entry.crc
        end

        def csv_entry(archive)
          entry = Zip::File.open_buffer(StringIO.new(archive)).entries.find { |e| e.file? && e.name.end_with?(".csv") }
          raise BuildError, "the CGN archive has no CSV file" unless entry
          raise BuildError, "the CGN CSV is larger than #{MAX_CSV_BYTES} bytes" if entry.size > MAX_CSV_BYTES

          entry
        end

        # False when the builder stopped reading; its error is the one reported.
        def write(writer, chunk)
          writer.write(chunk)
          true
        rescue Errno::EPIPE, IOError
          false
        end

        def thread(&) = Thread.new(&).tap { |thread| thread.report_on_exception = false }
      end
    end
  end
end
