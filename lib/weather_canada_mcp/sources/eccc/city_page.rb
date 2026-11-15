# frozen_string_literal: true

require "time"

module WeatherCanadaMCP
  module Sources
    module ECCC
      # ECCC's City Page weather (one item of the citypageweather-realtime collection) as plain Ruby objects. This is the only
      # class that knows City Page's property names; text comes in the language asked for.
      class CityPage
        WIND_CHILL_MAX_C = 0
        HUMIDEX_MIN_C = 20

        Warning = Data.define(:headline, :type, :colour, :issued_at, :expires_at, :url)
        Conditions = Data.define(:observed_at, :station, :condition, :temperature_c, :dewpoint_c, :humidity_pct, :wind_speed_kmh,
                                 :wind_gust_kmh, :wind_direction, :pressure_kpa, :pressure_tendency, :wind_chill, :humidex,
                                 :visibility_km)
        Period = Data.define(:name, :text, :temperatures, :precipitation, :snow_level, :wind, :uv_index, :humidity_pct)
        Hour = Data.define(:time, :condition, :temperature_c, :precip_chance_pct, :wind_speed_kmh, :wind_gust_kmh, :wind_direction,
                           :wind_chill, :humidex)
        # conditions is nil without a current report; periods and hours are in order; normals is the regional normals text.
        Forecast = Data.define(:url, :issued_at, :warnings, :conditions, :periods, :hours, :sunrise, :sunset, :normals)

        # hours is how many hourly entries to build (all by default).
        def self.parse(properties, lang:, hours: nil) = new(lang, hours).parse(properties)

        def initialize(lang, hours)
          @lang = lang
          @hours = hours
        end

        def parse(properties)
          rise_set = properties["riseSet"].is_a?(Hash) ? properties["riseSet"] : {}
          Forecast.new(
            url: text(properties["url"]), issued_at: instant(properties.dig("forecastGroup", "timestamp")),
            warnings: Array(properties["warnings"]).map { |warning| warning(warning) },
            conditions: conditions(properties["currentConditions"]),
            periods: Array(properties.dig("forecastGroup", "forecasts")).map { |period| period(period) },
            hours: hourly(properties.dig("hourlyForecastGroup", "hourlyForecasts")),
            sunrise: instant(rise_set["sunrise"]), sunset: instant(rise_set["sunset"]),
            normals: text(properties.dig("forecastGroup", "regionalNormals", "textSummary"))
          )
        end

        private

        def warning(warning)
          Warning.new(headline: text(warning["description"]), type: text(warning["type"]), colour: text(warning["alertColourLevel"]),
                      issued_at: instant(warning["eventIssue"]), expires_at: instant(warning["expiryTime"]), url: text(warning["url"]))
        end

        def conditions(conditions) # rubocop:disable Metrics/AbcSize -- one line per reading
          return unless conditions.is_a?(Hash) && conditions.key?("timestamp")

          temperature = value(conditions["temperature"])
          Conditions.new(
            observed_at: instant(conditions["timestamp"]), station: value(conditions["station"]), condition: text(conditions["condition"]),
            temperature_c: temperature, dewpoint_c: value(conditions["dewpoint"]), humidity_pct: value(conditions["relativeHumidity"]),
            wind_speed_kmh: value(conditions.dig("wind", "speed")), wind_gust_kmh: positive(value(conditions.dig("wind", "gust"))),
            wind_direction: value(conditions.dig("wind", "direction")), pressure_kpa: value(conditions["pressure"]),
            pressure_tendency: text(conditions.dig("pressure", "tendency")),
            wind_chill: feels_like(value(conditions["windChill"]), temperature, WIND_CHILL_MAX_C, :below),
            humidex: feels_like(value(conditions["humidex"]), temperature, HUMIDEX_MIN_C, :above),
            visibility_km: value(conditions["visibility"])
          )
        end

        def period(forecast)
          Period.new(
            name: text(forecast.dig("period", "textForecastName")), text: text(forecast["textSummary"]),
            temperatures: temperatures(forecast.dig("temperatures", "temperature")),
            precipitation: precipitation(forecast["precipitation"]), snow_level: text(forecast.dig("snowLevel", "textSummary")),
            wind: text(forecast.dig("winds", "textSummary")),
            uv_index: text(forecast.dig("uv", "index"))&.then { |index| Integer(index, exception: false) || index },
            humidity_pct: value(forecast["relativeHumidity"])
          )
        end

        def hourly(list)
          list = Array(list)
          (@hours ? list.first(@hours) : list).map { |hour| hour(hour) }
        end

        def hour(hour)
          Hour.new(
            time: time(hour["timestamp"]), condition: text(hour["condition"]), temperature_c: value(hour["temperature"]),
            precip_chance_pct: value(hour["lop"]), wind_speed_kmh: value(hour.dig("wind", "speed")),
            wind_gust_kmh: positive(value(hour.dig("wind", "gust"))), wind_direction: value(hour.dig("wind", "direction")),
            wind_chill: value(hour["windChill"]), humidex: value(hour["humidex"])
          )
        end

        def temperatures(list)
          Array(list).to_h { |entry| [:"#{text(entry["class"])}_c", value(entry)] }.except(:_c)
        end

        def precipitation(precipitation)
          amount = precipitation&.dig("accumulation", "amount")
          return unless amount

          unit = text(amount["units"])
          { type: text(precipitation.dig("accumulation", "name")), (unit == "cm" ? :amount_cm : :amount_mm) => value(amount) }
        end

        # City Page puts the reading under "value" as a bilingual pair ({"value" => {"en" => 4.2, "fr" => 4.2}}).
        def value(node) = node.is_a?(Hash) ? text(node["value"]) : nil

        # A bilingual field ({"en" => ..., "fr" => ...}) in the language asked for.
        def text(node)
          return node unless node.is_a?(Hash) && (node.key?("en") || node.key?("fr"))

          node[@lang] || node["en"]
        end

        def instant(node) = time(text(node))

        def time(value)
          Time.iso8601(value) if value.is_a?(String)
        rescue ArgumentError
          nil
        end

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
end
