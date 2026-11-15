# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Place name (or coordinates) to candidate places and the nearest City Page forecast sites.
    class FindLocation < Base
      NAME = "find_location"
      TITLE = "Find a location"
      DESCRIPTION = <<~TEXT.tr("\n", " ").strip
        Resolve a Canadian place name (town, park, lake, mountain, river) or coordinates to matching places and the
        nearest Environment Canada forecast sites. Use it to disambiguate a name before other tools (several places
        can share one name: check type and province), or to see which forecast site covers a remote spot and how far
        away it is. Other tools accept the same location text directly, so call this only when the place is ambiguous
        or you need the candidates.
      TEXT
      MAX_CANDIDATES = 10
      INPUT_SCHEMA = {
        type: "object",
        properties: {
          query: { type: "string", maxLength: Base::MAX_LOCATION_LENGTH,
                   description: "Place name, optionally with a province (\"Garibaldi, BC\"). Omit when giving lat and lon." },
          province: { type: "string", maxLength: 40, description: "Only places in this province or territory: code or name (\"AB\")." },
          lat: Base::LOCATION_PROPERTIES[:lat],
          lon: Base::LOCATION_PROPERTIES[:lon],
          limit: { type: "integer", minimum: 1, maximum: MAX_CANDIDATES, default: 5, description: "Most candidates to return." },
          **Base::LANG_PROPERTY
        },
        additionalProperties: false
      }.freeze

      def call(arguments)
        lang = lang(arguments)
        limit = integer_argument(arguments, "limit", 5, 1..MAX_CANDIDATES)
        if arguments["lat"].nil? && arguments["lon"].nil?
          by_name(arguments, limit, lang)
        else
          by_point(coordinates(arguments["lat"], arguments["lon"]), limit, lang)
        end
      end

      private

      def by_name(arguments, limit, lang)
        query = arguments["query"]
        raise InvalidArguments, "Give a query, or lat and lon." unless query.is_a?(String) && !query.strip.empty?
        raise InvalidArguments, "query is longer than #{MAX_LOCATION_LENGTH} characters." if query.length > MAX_LOCATION_LENGTH

        name, province = Places::Gazetteer.split_province(query)
        if arguments["province"]
          province = Places::Gazetteer.province_name(arguments["province"]) or
            raise InvalidArguments, "Unknown province #{arguments["province"].to_s[0, 40].inspect}; use a code such as AB or a name such as Alberta."
        end

        candidates = gazetteer.search(name, province:, limit:)
        return { query:, candidates: [], note: "No matching place. Try a shorter name, another spelling, or lat and lon." } if candidates.empty?

        best = candidates.first
        { query:, candidates: candidates.map(&:to_h), forecast_sites: sites(best.lat, best.lon, lang),
          note: "forecast_sites are for the first candidate." }
      end

      def by_point(point, limit, lang)
        nearby = nearby_places(point, limit)
        { lat: point.lat, lon: point.lon, nearby_places: nearby, forecast_sites: sites(point.lat, point.lon, lang) }.compact
      end

      # Reverse lookup is optional: without the gazetteer, coordinates still resolve to forecast sites.
      def nearby_places(point, limit)
        return unless @context.places.available?

        @context.places.get.nearest(point.lat, point.lon, radius_km: 15, limit:).map do |distance, place|
          place.to_h.merge(distance_km: round_km(distance))
        end
      rescue Places::Gazetteer::Unavailable
        nil
      end

      def sites(lat, lon, lang)
        locator.nearest_sites(lat, lon, limit: 3).map do |distance, site|
          { site_id: site.id, name: site.name_in(lang), region: site.region_in(lang), lat: site.lat, lon: site.lon,
            distance_km: round_km(distance) }
        end
      end
    end
  end
end
