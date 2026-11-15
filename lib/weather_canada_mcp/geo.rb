# frozen_string_literal: true

module WeatherCanadaMCP
  # Small spherical helpers. Coordinates are decimal degrees; GeoJSON positions are [lon, lat].
  module Geo
    EARTH_RADIUS_KM = 6371.0088
    KM_PER_DEGREE_LAT = 111.32

    COMPASS = %w[N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW].freeze

    module_function

    # The 16-point compass name for a bearing in degrees ("SW"); French writes west as O.
    def compass(degrees, lang = "en")
      name = COMPASS[((degrees % 360) / 22.5).round % 16]
      lang == "fr" ? name.tr("W", "O") : name
    end

    def distance_km(lat1, lon1, lat2, lon2)
      phi1 = radians(lat1)
      phi2 = radians(lat2)
      d_phi = radians(lat2 - lat1)
      d_lambda = radians(lon2 - lon1)
      a = (Math.sin(d_phi / 2)**2) + (Math.cos(phi1) * Math.cos(phi2) * (Math.sin(d_lambda / 2)**2))
      2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(a.clamp(0.0, 1.0)))
    end

    # [min_lon, min_lat, max_lon, max_lat] around a point, radius_km in every direction.
    def bbox(lat, lon, radius_km)
      d_lat = radius_km / KM_PER_DEGREE_LAT
      d_lon = radius_km / (KM_PER_DEGREE_LAT * [Math.cos(radians(lat)), 0.01].max)
      [lon - d_lon, lat - d_lat, lon + d_lon, lat + d_lat].map { |value| value.round(5) }
    end

    # Whether a GeoJSON Polygon or MultiPolygon contains the point. Holes are honoured; other geometry types never
    # contain a point.
    def contains?(geometry, lat, lon)
      return false unless geometry.is_a?(Hash)

      case geometry["type"]
      when "Polygon" then polygon_contains?(geometry["coordinates"], lat, lon)
      when "MultiPolygon" then Array(geometry["coordinates"]).any? { |polygon| polygon_contains?(polygon, lat, lon) }
      else false
      end
    end

    def polygon_contains?(rings, lat, lon)
      return false unless rings.is_a?(Array) && rings.any?

      outer, *holes = rings
      ring_contains?(outer, lat, lon) && holes.none? { |hole| ring_contains?(hole, lat, lon) }
    end

    # Even-odd ray casting.
    def ring_contains?(ring, lat, lon)
      return false unless ring.is_a?(Array) && ring.size >= 3

      inside = false
      ring += [ring.first] unless ring.first == ring.last
      ring.each_cons(2) do |(x1, y1), (x2, y2)|
        next unless (y1 > lat) != (y2 > lat)

        inside = !inside if lon < ((x2 - x1) * (lat - y1) / (y2 - y1)) + x1
      end
      inside
    end

    # Approximate distance in km from a point to the nearest edge of a GeoJSON Polygon or MultiPolygon (on a plane
    # tangent at the point, which is close enough within a few tens of km); nil for other geometry types.
    def distance_to_edge_km(geometry, lat, lon)
      scale = KM_PER_DEGREE_LAT * Math.cos(radians(lat))
      project = ->((x, y)) { [(x - lon) * scale, (y - lat) * KM_PER_DEGREE_LAT] if x.is_a?(Numeric) && y.is_a?(Numeric) }
      rings(geometry).flat_map { |ring| ring.filter_map(&project).each_cons(2).map { |a, b| segment_distance(a, b) } }.min
    end

    # Every ring of a Polygon or MultiPolygon; none for other geometry types.
    def rings(geometry)
      polygons = case geometry.is_a?(Hash) && geometry["type"]
                 when "Polygon" then [geometry["coordinates"]]
                 when "MultiPolygon" then geometry["coordinates"]
                 end
      Array(polygons).flat_map { |polygon| Array(polygon) }.grep(Array)
    end

    # Distance from the origin to the segment a-b, in the segment's units.
    def segment_distance((ax, ay), (bx, by))
      dx = bx - ax
      dy = by - ay
      length = (dx * dx) + (dy * dy)
      t = length.zero? ? 0.0 : (-((ax * dx) + (ay * dy)) / length).clamp(0.0, 1.0)
      Math.hypot(ax + (t * dx), ay + (t * dy))
    end

    def radians(degrees) = degrees * Math::PI / 180
  end
end
