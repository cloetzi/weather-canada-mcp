# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"

module WeatherCanadaMcp
  module Sources
    # Avalanche Canada's public services, used only when AVALANCHE_CANADA_ENABLED is true: avalanche forecast products
    # and their metadata, its mountain weather stations, and Mountain Information Network (MIN) field reports. Returns
    # parsed JSON, cached per URL.
    class AvalancheCanada
      # Seconds, before WEATHER_MCP_CACHE_SCALE.
      TTLS = { product: 1200, metadata: 3600, stations: 86_400, measurements: 600, submissions: 900 }.freeze
      LANGS = %w[en fr].freeze
      NAMES = { avalanche: "Avalanche Canada", avalanche_weather: "Avalanche Canada's weather station service" }.freeze
      MAX_SUBMISSION_DAYS = 31

      def initialize(http:, cache:)
        @http = http
        @cache = cache
      end

      # The forecast product covering a point. The point is rounded to 0.01 degrees (about 1 km), so nearby calls share a
      # cache entry. A point outside every forecast region returns a product with an empty id.
      def product_at(lat, lon, lang)
        query = URI.encode_www_form(lat: coordinate(lat), long: coordinate(lon))
        get(:avalanche, "/forecasts/#{check_lang(lang)}/products/point?#{query}", TTLS[:product], Hash)
      end

      # Every current forecast product, with its area, owner, highest danger and rating icons.
      def metadata(lang) = get(:avalanche, "/forecasts/#{check_lang(lang)}/metadata", TTLS[:metadata], Array)

      def stations = get(:avalanche_weather, "/stations", TTLS[:stations], Array)

      # Hourly measurements between two times, newest first.
      def measurements(station_id, from:, to:)
        raise ArgumentError, "invalid station id" unless station_id.is_a?(Integer) && station_id.positive?

        query = URI.encode_www_form(fromDate: from.utc.iso8601, toDate: to.utc.iso8601)
        get(:avalanche_weather, "/stations/#{station_id}/measurements?#{query}", TTLS[:measurements], Array)
      end

      # MIN submissions observed between two dates (at most 31 days) inside bbox [min_lon, min_lat, max_lon, max_lat].
      def submissions(from:, to:, bbox:)
        raise ArgumentError, "invalid date range" unless from.is_a?(Date) && to.is_a?(Date) && from <= to
        raise ArgumentError, "the date range is longer than #{MAX_SUBMISSION_DAYS} days" if to - from >= MAX_SUBMISSION_DAYS
        raise ArgumentError, "invalid bbox" unless bbox.size == 4 && bbox.all?(Numeric)

        query = URI.encode_www_form(fromdate: from.iso8601, todate: to.iso8601, bbox: bbox.join(","))
        data = get(:avalanche, "/min/submissions?#{query}", TTLS[:submissions], Hash)
        items = data["items"]
        items.is_a?(Array) ? items : raise(InvalidResponse, "#{NAMES[:avalanche]} returned field reports in an unexpected shape.")
      end

      private

      def check_lang(lang) = LANGS.include?(lang) ? lang : raise(ArgumentError, "invalid lang")

      def coordinate(value)
        raise ArgumentError, "invalid coordinate" unless value.is_a?(Numeric) && value.to_f.finite?

        format("%.2f", value)
      end

      def get(origin, path, ttl, shape)
        @cache.fetch("#{origin}:#{path}", ttl:) do
          response = @http.get(origin, path)
          raise StatusError.new(response.status, NAMES.fetch(origin)) unless response.success?

          parse(response.body, NAMES.fetch(origin), shape)
        end
      end

      def parse(body, name, shape)
        data = JSON.parse(body.dup.force_encoding(Encoding::UTF_8), max_nesting: 64)
        raise InvalidResponse, "#{name} returned JSON in an unexpected shape." unless data.is_a?(shape)

        data
      rescue JSON::ParserError
        raise InvalidResponse, "#{name} returned a response that is not valid JSON."
      end
    end
  end
end
