# frozen_string_literal: true

require "uri"

module WeatherCanadaMCP
  module Sources
    module ECCC
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
          "marineweather-realtime" => 900,
          "ltce-temperature" => 86_400,
          "ltce-precipitation" => 86_400,
          "ltce-snowfall" => 86_400,
          "climate-normals" => 7 * 86_400
        }.freeze
        DEFAULT_TTL = 600
        SITE_LIST_TTL = 86_400
        COLLECTION = /\A[a-z0-9:-]{1,80}\z/
        ITEM_ID = /\A[\w.:-]{1,120}\z/

        def initialize(http:, cache:, logger: nil)
          @json = JsonClient.new(http:, cache:, origin: :eccc_api)
          @logger = logger
        end

        # params are OGC API query parameters (bbox, limit, properties, sortby, datetime, lang, or property filters).
        def items(collection, ttl: nil, **params)
          check(collection, COLLECTION, "collection")
          data = get("/collections/#{collection}/items?#{URI.encode_www_form({ f: "json" }.merge(params))}", ttl || ttl_for(collection))
          warn_if_truncated(collection, data) unless params.key?(:sortby)
          data
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

        # A list cut short by its limit hides stations or records the caller needed. A sorted query asks for the first few
        # on purpose, so it is not reported. The log names the collection only, never the query.
        def warn_if_truncated(collection, data)
          matched = data["numberMatched"]
          returned = data["numberReturned"]
          return unless @logger && matched.is_a?(Integer) && returned.is_a?(Integer) && matched > returned

          @logger.warn("ogc_truncated", collection:, matched:, returned:)
        end

        def get(path, ttl) = @json.get(path, ttl, accept: "application/geo+json, application/json")
      end
    end
  end
end
