# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Current conditions, the official text forecast, hourly forecast and sun times from the nearest City Page site.
    class GetForecast < Base
      MAX_HOURS = 24
      WIND_CHILL_MAX_C = 0
      HUMIDEX_MIN_C = 20
      DISTANT_SITE_KM = 50
      tool_name "get_forecast"
      title "Get the weather forecast"
      description <<~TEXT
        Environment Canada's forecast for the nearest of ~850 forecast sites: current conditions, the official
        human-written forecast by period (today, tonight, then about 6 days, including snow levels in the mountains
        where ECCC issues them), an hourly forecast, sunrise/sunset and active warning headlines. All times are UTC
        (ISO 8601). The result names the site used and its distance from the location; a site tens of km away, or at a
        different elevation, may not match conditions in the backcountry. For full alert text use get_alerts.
      TEXT
      location_arguments
      argument :hours, :integer, in: 0..MAX_HOURS, default: 12, description: "Hourly forecast entries to include (0 to omit)."
      argument :lang, :language

      def call(args)
        @lang = args.lang # one tool instance serves one call, so this is not shared between requests
        point = args.point
        hours = args.hours
        distance, site = forecast_sites.nearest_sites(point.lat, point.lon, limit: 1).first
        properties = ogc.item(Sources::ECCC::ForecastSites::COLLECTION, site.id).fetch("properties") do
          raise Sources::InvalidResponse, "api.weather.gc.ca returned a forecast without properties."
        end
        shape(properties, site, distance, point, hours)
      end

      private

      def shape(properties, site, distance, point, hours)
        {
          location: point.to_h,
          forecast_site: site_info(properties, site, distance),
          issued_at: text(properties.dig("forecastGroup", "timestamp")),
          warnings: warnings(properties["warnings"]),
          current_conditions: current(properties["currentConditions"]),
          forecast: Array(properties.dig("forecastGroup", "forecasts")).map { |period| period(period) },
          hourly: (hourly(properties.dig("hourlyForecastGroup", "hourlyForecasts"), hours) if hours.positive?),
          sun: sun(properties["riseSet"]),
          normals: text(properties.dig("forecastGroup", "regionalNormals", "textSummary"))
        }
      end

      def site_info(properties, site, distance)
        info = { site_id: site.id, name: site.name_in(@lang), region: site.region_in(@lang), distance_km: round_km(distance),
                 url: text(properties["url"]) }
        info[:note] = "The nearest forecast site is #{round_km(distance)} km away; conditions there may differ." if distance > DISTANT_SITE_KM
        info
      end

      def warnings(list)
        Array(list).map do |warning|
          { headline: text(warning["description"]), type: text(warning["type"]), colour: text(warning["alertColourLevel"]),
            issued_at: text(warning["eventIssue"]), expires_at: text(warning["expiryTime"]), url: text(warning["url"]) }
        end
      end

      def current(conditions) # rubocop:disable Metrics/AbcSize -- one line per reading
        return unless conditions.is_a?(Hash) && conditions.key?("timestamp")

        temperature = value(conditions["temperature"])
        {
          observed_at: text(conditions["timestamp"]), station: value(conditions["station"]),
          condition: text(conditions["condition"]), temperature_c: temperature, dewpoint_c: value(conditions["dewpoint"]),
          humidity_pct: value(conditions["relativeHumidity"]),
          wind_kmh: value(conditions.dig("wind", "speed")), wind_gust_kmh: positive(value(conditions.dig("wind", "gust"))),
          wind_direction: value(conditions.dig("wind", "direction")),
          pressure_kpa: value(conditions["pressure"]), pressure_tendency: text(conditions.dig("pressure", "tendency")),
          wind_chill: feels_like(value(conditions["windChill"]), temperature, WIND_CHILL_MAX_C, :below),
          humidex: feels_like(value(conditions["humidex"]), temperature, HUMIDEX_MIN_C, :above),
          visibility_km: value(conditions["visibility"])
        }
      end

      def period(forecast)
        {
          name: text(forecast.dig("period", "textForecastName")),
          text: text(forecast["textSummary"]),
          temperatures: temperatures(forecast.dig("temperatures", "temperature")),
          precipitation: precipitation(forecast["precipitation"]),
          snow_level: text(forecast.dig("snowLevel", "textSummary")),
          wind: text(forecast.dig("winds", "textSummary")),
          uv_index: text(forecast.dig("uv", "index"))&.then { |index| Integer(index, exception: false) || index },
          humidity_pct: value(forecast["relativeHumidity"])
        }
      end

      def temperatures(list)
        Array(list).to_h { |entry| [:"#{text(entry["class"])}_c", value(entry)] }.except(:_c)
      end

      def precipitation(precipitation)
        amount = precipitation&.dig("accumulation", "amount")
        return unless amount

        { type: text(precipitation.dig("accumulation", "name")), amount: value(amount), units: text(amount["units"]) }
      end

      def hourly(list, hours)
        Array(list).first(hours).map do |hour|
          {
            time: hour["timestamp"], condition: text(hour["condition"]), temperature_c: value(hour["temperature"]),
            precip_chance_pct: value(hour["lop"]),
            wind_kmh: value(hour.dig("wind", "speed")), wind_gust_kmh: positive(value(hour.dig("wind", "gust"))),
            wind_direction: value(hour.dig("wind", "direction")),
            wind_chill: value(hour["windChill"]), humidex: value(hour["humidex"])
          }
        end
      end

      def sun(rise_set)
        return unless rise_set.is_a?(Hash)

        { sunrise: text(rise_set["sunrise"]), sunset: text(rise_set["sunset"]) }
      end

      # City Page puts the reading under "value" as a bilingual pair ({"value" => {"en" => 4.2, "fr" => 4.2}}).
      def value(node) = node.is_a?(Hash) ? text(node["value"]) : nil

      def text(node) = localized(node, @lang)

      def positive(number) = number.is_a?(Numeric) && number.positive? ? number : nil

      # ECCC reports wind chill at or below 0 °C and humidex from 20 °C. City Page sometimes carries a stale value
      # outside that range (a wind chill of -1 at +11 °C), which would mislead, so it is dropped.
      def feels_like(number, temperature, threshold, side)
        return unless number.is_a?(Numeric) && temperature.is_a?(Numeric)

        applies = side == :below ? temperature <= threshold && number < temperature : temperature >= threshold && number > temperature
        number if applies
      end
    end
  end
end
