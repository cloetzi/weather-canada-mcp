# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Turns a tool's location arguments into a Base::Point: coordinates, or a place name looked up in the gazetteer.
    module PointResolution
      # A same-named place counts as an alternative when its score is at least this share of the best match's, it is in
      # another province or is another type of place, and it is not just a second record of the same spot.
      AMBIGUITY_SHARE = 0.8
      AMBIGUITY_MAX = 3
      SAME_SPOT_KM = 10

      private

      # lat/lon win over location; one of the two is required.
      def resolve_point(args)
        return coordinates(args.lat, args.lon) unless args.lat.nil? && args.lon.nil?

        raise InvalidArguments, "Give a location name, or lat and lon." if args.location.nil? || args.location.strip.empty?

        place, others = lookup(args.location)
        place_names_used!
        Base::Point.new(lat: place.lat, lon: place.lon, place:, zone: zone_at(place.lat, place.lon), others:)
      end

      def coordinates(lat, lon)
        raise InvalidArguments, "Give both lat and lon." if lat.nil? || lon.nil?
        raise InvalidArguments, "lat and lon must be numbers." unless lat.is_a?(Numeric) && lon.is_a?(Numeric)
        unless Base::CANADA_LAT.cover?(lat) && Base::CANADA_LON.cover?(lon)
          raise InvalidArguments, "#{lat}, #{lon} is outside Canada; ECCC data covers Canada only (lon is negative, west)."
        end

        Base::Point.new(lat: lat.to_f, lon: lon.to_f, place: nil, zone: zone_at(lat, lon))
      end

      # Without the forecast site list (ECCC down), times fall back to UTC, which their offsets say.
      def zone_at(lat, lon)
        forecast_sites.zone_at(lat, lon)
      rescue Sources::Error
        Sources::ECCC::ForecastSites::FALLBACK_ZONE
      end

      def lookup(location)
        name, province = Places::Gazetteer.split_province(location)
        place, *rest = gazetteer.search(name, province:, limit: AMBIGUITY_MAX + 1)
        return [place, alternatives(place, rest)] if place

        raise NotFound, "No place named #{name.inspect}#{" in #{province}" if province} was found. " \
                        "Try find_location with a shorter or different name, or pass lat and lon."
      end

      def alternatives(place, rest)
        key = Places::Gazetteer.normalize(place.name)
        rest.select do |other|
          Places::Gazetteer.normalize(other.name) == key && other.score >= place.score * AMBIGUITY_SHARE &&
            (other.province != place.province || other.type != place.type) &&
            Geo.distance_km(place.lat, place.lon, other.lat, other.lon) > SAME_SPOT_KM
        end.first(AMBIGUITY_MAX)
      end

      def gazetteer
        @context.gazetteer.open
      rescue Places::Gazetteer::Unavailable => e
        raise Unavailable, "Place names cannot be looked up right now (#{e.message}). Pass lat and lon instead."
      end
    end
  end
end
