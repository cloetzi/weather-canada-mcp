# frozen_string_literal: true

module WeatherCanadaMcp
  # Small spherical helpers. Coordinates are decimal degrees; GeoJSON positions are [lon, lat].
  module Geo
    EARTH_RADIUS_KM = 6371.0088
    KM_PER_DEGREE_LAT = 111.32

    module_function

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

    def radians(degrees) = degrees * Math::PI / 180
  end
end
