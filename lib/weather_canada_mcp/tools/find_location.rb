# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Place name (or coordinates) to candidate places and the nearest City Page forecast sites.
    class FindLocation < Base
      MAX_CANDIDATES = 10
      tool_name "find_location"
      title "Find a location"
      description <<~TEXT
        Resolve a Canadian place name (town, park, lake, mountain, river) or coordinates to matching places and the nearest
        Environment Canada forecast sites. Other tools accept the same location text, so call this only when a name is
        ambiguous (check type and province) or to see which forecast site covers a remote spot.
      TEXT
      argument :location, :string, max_length: MAX_LOCATION_LENGTH,
                                   description: "Place name, optionally with a province (\"Garibaldi, BC\"). Omit when giving lat and lon."
      argument :province, :string, max_length: 40, description: "Only places in this province or territory: code or name (\"AB\")."
      coordinate_arguments
      argument :limit, :integer, in: 1..MAX_CANDIDATES, default: 5, description: "Most candidates to return."
      argument :lang, :language

      output :query, :string, "The place name searched for."
      output :candidates, :array, "Matching places, best first."
      output :forecast_sites, :array, "The nearest forecast sites."

      def call(args)
        if args.lat.nil? && args.lon.nil?
          by_name(args)
        else
          by_point(coordinates(args.lat, args.lon), args.limit, args.lang)
        end
      end

      private

      def by_name(args)
        query = args.location
        raise InvalidArguments, "Give a location, or lat and lon." if query.nil? || query.strip.empty?

        name, province = Places::Gazetteer.split_province(query)
        if args.province
          province = Places::Gazetteer.province_name(args.province) or
            raise InvalidArguments, "Unknown province #{args.province[0, 40].inspect}; use a code such as AB or a name such as Alberta."
        end

        candidates = gazetteer.search(name, province:, limit: args.limit)
        place_names_used!
        return { query:, candidates: [], note: "No matching place. Try a shorter name, another spelling, or lat and lon." } if candidates.empty?

        best = candidates.first
        { query:, candidates: candidates.map(&:to_h), forecast_sites: sites(best.lat, best.lon, args.lang),
          note: "forecast_sites are for the first candidate." }
      end

      def by_point(point, limit, lang)
        nearby = nearby_places(point, limit)
        place_names_used! unless nearby.nil?
        { lat: point.lat, lon: point.lon, nearby_places: nearby, forecast_sites: sites(point.lat, point.lon, lang) }.compact
      end

      # Reverse lookup is optional: without the gazetteer, coordinates still resolve to forecast sites.
      def nearby_places(point, limit)
        return unless @context.gazetteer.available?

        @context.gazetteer.open.nearest(point.lat, point.lon, radius_km: 15, limit:).map do |distance, place|
          place.to_h.merge(distance_km: round_km(distance))
        end
      rescue Places::Gazetteer::Unavailable
        nil
      end

      def sites(lat, lon, lang)
        forecast_sites.nearest_sites(lat, lon, limit: 3).map do |distance, site|
          { id: site.id, name: site.name_in(lang), region: site.region_in(lang), lat: site.lat, lon: site.lon,
            distance_km: round_km(distance) }
        end
      end
    end
  end
end
