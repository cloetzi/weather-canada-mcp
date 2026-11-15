# frozen_string_literal: true

require "async/promise"

module WeatherCanadaMcp
  class Gazetteer
    # Opens the gazetteer, building it on first use when the database is missing and auto_build is on: downloads the
    # CGN archive (~16 MB) through the upstream client, then inflates and loads it in background threads (streamed
    # through a pipe), so the reactor keeps serving other requests. Concurrent callers share one build. A failed
    # build is not retried for RETRY_AFTER seconds, so a broken setup does not re-download the archive on every call.
    class Provider
      CGN_PATH = "/pub/nrcan_rncan/vector/geobase_cgn_toponyme/prov_csv_eng/cgn_canada_csv_eng.zip"
      MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
      MAX_CSV_BYTES = 512 * 1024 * 1024
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
      end

      attr_reader :path

      def available? = !@gazetteer.nil? || File.file?(@path)

      def get
        return @gazetteer if @gazetteer

        opened = open_or_build
        # Another fiber may have opened it while this one waited for the build.
        return opened.tap { @gazetteer = opened } unless @gazetteer

        opened.close
        @gazetteer
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

        if @building
          @building.wait
        else
          build_once
        end
        Gazetteer.new(@path)
      end

      def build_once
        if @failure && @clock.call - @failure[:at] < RETRY_AFTER
          raise Unavailable, "#{@failure[:message]} (not retried for #{RETRY_AFTER / 60} minutes)"
        end

        @building = Async::Promise.new
        build
        @failure = nil
        @building.resolve(true)
      rescue Unavailable => e
        @failure = { at: @clock.call, message: e.message }
        raise
      ensure
        if @building && !@building.resolved?
          @building.reject(Unavailable.new(@failure ? @failure[:message] : "the place-name build was cancelled"))
        end
        @building = nil
      end

      def build
        @logger.info("gazetteer_download", path: @path, message: "downloading Canadian Geographical Names (one time)")
        response = @http.get(:cgn, CGN_PATH, accept: "application/zip", max_body_bytes: MAX_ARCHIVE_BYTES, timeout: DOWNLOAD_TIMEOUT)
        raise Upstream::StatusError.new(response.status, "ftp.maps.canada.ca") unless response.success?

        load(response.body)
      rescue Upstream::Error, Error, SystemCallError, SQLite3::Exception => e
        raise Unavailable, "the place-name database could not be built: #{e.message}"
      rescue StandardError => e # malformed CSV or text: the class says enough, the message could quote the data
        raise Unavailable, "the place-name database could not be built: the NRCan data could not be read (#{e.class})"
      end

      # The inflater writes the CSV into a pipe that the builder reads, so the whole CSV is never held in memory.
      def load(archive)
        reader, writer = IO.pipe
        reader.set_encoding("BOM|UTF-8")
        inflater = thread { inflate(archive, writer) }
        builder = thread { Builder.new(logger: @logger).build(reader, @path, source: "https://ftp.maps.canada.ca#{CGN_PATH}") }
        count = builder.value
        inflater.value
        count
      ensure
        reader&.close # an early builder failure makes the inflater's next write fail instead of block
        inflater&.join
      end

      def inflate(archive, writer)
        ZipEntry.first(archive, suffix: ".csv", max_bytes: MAX_CSV_BYTES) { |chunk| writer.write(chunk) }
      rescue Errno::EPIPE, IOError
        nil # the builder stopped reading; its error is the one reported
      ensure
        writer.close
      end

      def thread(&) = Thread.new(&).tap { |thread| thread.report_on_exception = false }
    end
  end
end
