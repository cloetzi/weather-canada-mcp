# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # The ECCC marine forecast (wind, weather and visibility, waves, freezing spray) for the marine area at a point, or
    # the nearest ones when the point is on land, from the marineweather-realtime collection.
    class GetMarineForecast < Base
      COLLECTION = "marineweather-realtime"
      NEARBY_KM = 25
      MAX_NEARBY = 2
      MAX_FEATURES = 50
      ENDED = "ENDED"
      CONDITIONS = { "wind" => :wind, "weatherVisibility" => :weather_visibility, "airTemperature" => :air_temperature,
                     "freezingSpray" => :freezing_spray }.freeze
      tool_name "get_marine_forecast"
      title "Get the marine forecast"
      description <<~TEXT
        Environment Canada's marine forecast for the marine area at a location (coastal waters, large lakes, Arctic
        waters): wind in knots, weather and visibility, waves, air temperature and freezing spray for today and tomorrow,
        the extended wind forecast, and marine warnings in effect. A point on land gets the nearest areas within 25 km.
        Quote warnings as given, without rewording or shortening. For alerts on land use get_alerts.
      TEXT
      location_arguments
      argument :lang, :language

      output :marine_areas, :array, "The marine areas, nearest first."
      output :source_url, :string, "The official marine forecast page."

      def call(args)
        lang = args.lang
        point = args.point
        data = ogc.items(COLLECTION, bbox: Geo.bbox(point.lat, point.lon, NEARBY_KM).join(","), limit: MAX_FEATURES)
        areas = matching_areas(Array(data["features"]), point)
        result = { location: point.to_h, marine_areas: areas.map { |distance, feature| area(feature, distance, lang) },
                   source_url: lang == "fr" ? "https://meteo.gc.ca/marine/index_f.html" : "https://weather.gc.ca/marine/index_e.html" }
        result[:note] = "No marine forecast area within #{NEARBY_KM} km." if areas.empty?
        result
      end

      private

      # [[distance_km or nil, feature], ...]: the areas containing the point, else the nearest within NEARBY_KM.
      def matching_areas(features, point)
        features = features.select { |feature| feature["properties"].is_a?(Hash) }
        inside = features.select { |feature| Geo.contains?(feature["geometry"], point.lat, point.lon) }
        return inside.map { |feature| [nil, feature] } if inside.any?

        features.filter_map do |feature|
          distance = Geo.distance_to_edge_km(feature["geometry"], point.lat, point.lon)
          [distance, feature] if distance && distance <= NEARBY_KM
        end.min_by(MAX_NEARBY, &:first)
      end

      def area(feature, distance, lang)
        properties = feature["properties"]
        regular = properties["regularForecast"].is_a?(Hash) ? properties["regularForecast"] : {}
        {
          name: text(properties.dig("area", "value"), lang), region: text(properties.dig("area", "region"), lang),
          sub_region: text(properties.dig("area", "subRegion"), lang), distance_km: distance && round_km(distance),
          issued_at: issued(regular), warnings: warnings(properties["warnings"], lang),
          forecast: forecast(regular, properties["waveForecast"], lang), extended_forecast: extended(properties["extendedForecast"], lang)
        }
      end

      # One entry per part of the area (some areas are split, "Kane - northern half"), with its waves.
      def forecast(regular, waves, lang)
        wave_parts = locations(waves)
        locations(regular).map do |part|
          name = text(part["name"], lang)
          condition = part["weatherCondition"].is_a?(Hash) ? part["weatherCondition"] : {}
          wave = wave_part(wave_parts, name, lang)
          { part: name, status: text(part["statusStatement"], lang), period: text(condition["periodOfCoverage"], lang),
            **CONDITIONS.to_h { |key, field| [field, text(condition[key], lang)] },
            waves: (text(wave["textSummary"], lang) if wave.is_a?(Hash)) }
        end
      end

      # The wave forecast for a part of the area: the one with the same name, else the one for the whole area.
      def wave_part(parts, name, lang)
        part = parts.find { |entry| text(entry["name"], lang) == name } || (parts.first if parts.size == 1)
        part&.dig("weatherCondition")
      end

      def extended(extended, lang)
        return unless extended.is_a?(Hash)

        periods = locations(extended).flat_map do |part|
          Array(part.dig("weatherCondition", "forecastPeriods")).filter_map do |period|
            next unless period.is_a?(Hash)

            { part: text(part["name"], lang), period: text(period["name"], lang), forecast: text(period["value"], lang) }
          end
        end
        { issued_at: issued(extended), periods: } if periods.any?
      end

      # Marine warnings in effect; ECCC keeps ended ones listed for a while.
      def warnings(warnings, lang)
        locations(warnings).flat_map do |part|
          Array(part["events"]).filter_map do |event|
            next unless event.is_a?(Hash) && event.dig("status", "en") != ENDED

            { name: text(event["name"], lang), status: text(event["status"], lang), part: text(part["name"], lang) }
          end
        end
      end

      def locations(section) = section.is_a?(Hash) ? Array(section["locations"]).grep(Hash) : []

      def issued(section) = time(section["issuedDatetimeUTC"])

      # ECCC's text with runs of spaces closed up; nil when empty.
      def text(value, lang)
        value = localized(value, lang)
        return unless value.is_a?(String)

        value = value.squeeze(" ").strip
        value unless value.empty?
      end
    end
  end
end
