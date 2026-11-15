# frozen_string_literal: true

require "async/promise"
require "stringio"

module WeatherCanadaMcp
  class Gazetteer
    # Opens the gazetteer, building it on first use when the database is missing and auto_build is on: downloads the
    # CGN archive (~16 MB) through the upstream client and loads it in a background thread, so the reactor keeps
    # serving other requests. Concurrent callers share one build; a failed build is retried on a later call.
    class Provider
      CGN_PATH = "/pub/nrcan_rncan/vector/geobase_cgn_toponyme/prov_csv_eng/cgn_canada_csv_eng.zip"
      MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
      MAX_CSV_BYTES = 512 * 1024 * 1024

      def initialize(path:, http:, logger:, auto_build: true)
        @path = path
        @http = http
        @logger = logger
        @auto_build = auto_build
        @gazetteer = nil
        @building = nil
      end

      attr_reader :path

      def available? = !@gazetteer.nil? || File.file?(@path)

      def get
        @gazetteer ||= open_or_build # rubocop:disable Naming/MemoizedInstanceVariableName -- reopened by rebuild!
      end

      # Downloads and rebuilds unconditionally (the `gazetteer update` command), then reopens.
      def rebuild!
        build
        reopen
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
        @building = Async::Promise.new
        build
        @building.resolve(true)
      rescue StandardError => e
        @building.reject(e)
        raise
      ensure
        @building = nil
      end

      def build
        @logger.info("gazetteer_download", path: @path, message: "downloading Canadian Geographical Names (one time)")
        response = @http.get(:cgn, CGN_PATH, accept: "application/zip", max_body_bytes: MAX_ARCHIVE_BYTES)
        raise Upstream::StatusError.new(response.status, "ftp.maps.canada.ca") unless response.success?

        Thread.new { load(response.body) }.tap { |thread| thread.report_on_exception = false }.value
      rescue Upstream::Error, Error, SystemCallError, SQLite3::Exception => e
        raise Unavailable, "the place-name database could not be built: #{e.message}"
      end

      def load(archive)
        csv = String.new(encoding: Encoding::BINARY)
        ZipEntry.first(archive, suffix: ".csv", max_bytes: MAX_CSV_BYTES) { |chunk| csv << chunk }
        csv.force_encoding(Encoding::UTF_8).delete_prefix!("﻿")
        Builder.new(logger: @logger).build(StringIO.new(csv), @path, source: "https://ftp.maps.canada.ca#{CGN_PATH}")
      end

      def reopen
        @gazetteer&.close
        @gazetteer = Gazetteer.new(@path)
      end
    end
  end
end
