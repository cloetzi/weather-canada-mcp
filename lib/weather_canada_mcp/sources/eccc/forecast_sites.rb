# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    module ECCC
      # Finds the City Page forecast sites nearest a point. The site list (about 850 sites) comes from the OGC API and is
      # cached for a day.
      class ForecastSites
        COLLECTION = "citypageweather-realtime"
        SITE_PROPERTIES = "identifier,name.en,name.fr,region.en,region.fr"

        Site = Data.define(:id, :name, :region, :lat, :lon) do
          def name_in(lang) = name[lang] || name["en"]
          def region_in(lang) = region[lang] || region["en"]
        end

        def initialize(ogc:)
          @ogc = ogc
          @parsed = {}.compare_by_identity
        end

        # [[distance_km, Site], ...] closest first.
        def nearest_sites(lat, lon, limit: 3)
          sites.map { |site| [Geo.distance_km(lat, lon, site.lat, site.lon), site] }.min_by(limit, &:first)
        end

        def sites
          data = @ogc.items(COLLECTION, ttl: OgcApi::SITE_LIST_TTL, limit: 1000, properties: SITE_PROPERTIES)
          # The cache hands back the same object until it expires, so parse each list once.
          @parsed = { data => parse(data) }.compare_by_identity unless @parsed.key?(data)
          @parsed[data]
        end

        private

        def parse(data)
          sites = Array(data["features"]).filter_map do |feature|
            lon, lat = feature.dig("geometry", "coordinates")
            properties = feature["properties"] || {}
            next unless lat.is_a?(Numeric) && lon.is_a?(Numeric) && properties["identifier"].is_a?(String)

            Site.new(id: properties["identifier"], name: properties["name"] || {}, region: properties["region"] || {}, lat:, lon:)
          end
          raise InvalidResponse, "api.weather.gc.ca returned an empty City Page site list." if sites.empty?

          sites.freeze
        end
      end
    end
  end
end
