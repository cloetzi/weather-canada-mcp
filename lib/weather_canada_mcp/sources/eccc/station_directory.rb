# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    module ECCC
      # The stations (or locations) of one OGC API collection, searched for the nearest to a point in memory.
      #
      # A collection small enough to fetch whole (up to LIST_LIMIT features: the SWOB stations, the AQHI locations, the City
      # Page sites) is read once per TTL, so every point shares one cached response. A collection too large for that (the
      # real-time hydrometric gauges, 2,600 of them, or the climate normals) is read for the 0.5 degree grid cell around the
      # point instead (Geo.snapped_bbox), so points in the same cell share a response and the response stays small.
      class StationDirectory
        LIST_LIMIT = 1000
        AREA_LIMIT = 500

        # grid: true reads the cell around the point instead of the whole collection. params are OGC API query parameters
        # that select the stations (REAL_TIME: 1, latest: true), properties the fields to keep.
        def initialize(ogc:, collection:, properties: nil, ttl: nil, grid: false, **params)
          @ogc = ogc
          @collection = collection
          @ttl = ttl
          @grid = grid
          @params = { properties:, **params }.compact
          @parsed = {}.compare_by_identity
        end

        # [[distance_km, feature], ...] closest first: the count nearest point features within radius_km (any distance
        # without one) that the block, when given, accepts.
        def nearest(lat, lon, count:, radius_km: nil, &accept)
          located(lat, lon, radius_km).filter_map do |feature, station_lat, station_lon|
            next if accept && !accept.call(feature)

            distance = Geo.distance_km(lat, lon, station_lat, station_lon)
            [distance, feature] if radius_km.nil? || distance <= radius_km
          end.min_by(count, &:first)
        end

        # Every point feature of the collection (the whole-list mode only).
        def features = located(nil, nil, nil).map(&:first)

        private

        def located(lat, lon, radius_km)
          data = @grid ? area(lat, lon, radius_km) : list
          @parsed = { data => parse(data) }.compare_by_identity unless @parsed.key?(data)
          @parsed[data]
        end

        def list = @ogc.items(@collection, **ttl_params, **@params, limit: LIST_LIMIT)

        def area(lat, lon, radius_km)
          @ogc.items(@collection, **ttl_params, **@params, bbox: Geo.snapped_bbox(lat, lon, radius_km).join(","), limit: AREA_LIMIT)
        end

        def ttl_params = @ttl ? { ttl: @ttl } : {}

        # The cache hands back the same object until it expires, so each response is parsed once.
        def parse(data)
          Array(data["features"]).filter_map do |feature|
            lon, lat = feature.dig("geometry", "coordinates")
            [feature, lat, lon] if lat.is_a?(Numeric) && lon.is_a?(Numeric) && feature["properties"].is_a?(Hash)
          end.freeze
        end
      end
    end
  end
end
