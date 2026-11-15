# frozen_string_literal: true

require "json"
require "uri"

module WeatherCanadaMcp
  module Sources
    # MSC GeoMet OGC API Features (api.weather.gc.ca): /collections/{id}/items queries and single items, as parsed
    # GeoJSON. Responses are cached per URL for the collection's TTL.
    class OgcApi
      # Seconds, before WEATHER_MCP_CACHE_SCALE.
      TTLS = {
        "citypageweather-realtime" => 600,
        "weather-alerts" => 300,
        "swob-realtime" => 300,
        "swob-stations" => 86_400,
        "hydrometric-stations" => 86_400,
        "hydrometric-realtime" => 900,
        "hydrometric-monthly-mean" => 7 * 86_400,
        "aqhi-observations-realtime" => 900,
        "aqhi-forecasts-realtime" => 900,
        "marineweather-realtime" => 900
      }.freeze
      DEFAULT_TTL = 600
      SITE_LIST_TTL = 86_400
      COLLECTION = /\A[a-z0-9:-]{1,80}\z/
      ITEM_ID = /\A[\w.:-]{1,120}\z/

      def initialize(http:, cache:)
        @http = http
        @cache = cache
      end

      # params are OGC API query parameters (bbox, limit, properties, sortby, datetime, lang, or property filters).
      def items(collection, ttl: nil, **params)
        check(collection, COLLECTION, "collection")
        get("/collections/#{collection}/items?#{URI.encode_www_form({ f: "json" }.merge(params))}", ttl || ttl_for(collection))
      end

      def item(collection, id, ttl: nil)
        check(collection, COLLECTION, "collection")
        check(id, ITEM_ID, "item id")
        get("/collections/#{collection}/items/#{URI.encode_uri_component(id)}?f=json", ttl || ttl_for(collection))
      end

      private

      def ttl_for(collection) = TTLS.fetch(collection, DEFAULT_TTL)

      def check(value, pattern, label)
        raise ArgumentError, "invalid #{label}" unless value.is_a?(String) && value.match?(pattern)
      end

      def get(path, ttl)
        @cache.fetch("api:#{path}", ttl:) do
          response = @http.get(:api, path, accept: "application/geo+json, application/json")
          raise Sources::StatusError.new(response.status, "api.weather.gc.ca") unless response.success?

          parse(response.body)
        end
      end

      def parse(body)
        data = JSON.parse(body.dup.force_encoding(Encoding::UTF_8), max_nesting: 64)
        raise Sources::InvalidResponse, "api.weather.gc.ca returned JSON that is not an object." unless data.is_a?(Hash)

        data
      rescue JSON::ParserError
        raise Sources::InvalidResponse, "api.weather.gc.ca returned a response that is not valid JSON."
      end
    end
  end
end
