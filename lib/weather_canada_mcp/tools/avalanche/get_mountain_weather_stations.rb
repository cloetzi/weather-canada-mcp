# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    module Avalanche
      # The mountain weather stations on Avalanche Canada's map nearest a point: the latest hourly reading and a summary
      # of the past hours.
      class GetMountainWeatherStations < Base
        MAX_RADIUS_KM = 100
        MAX_HOURS = 168
        MAX_STATIONS = 6
        SPARE_STATIONS = 2
        STALE_AFTER = 3 * 3600
        tool_name "get_mountain_weather_stations"
        title "Get mountain weather stations"
        description <<~TEXT
          The mountain weather stations nearest a location from Avalanche Canada's station network (run by Parks Canada,
          provincial agencies, ski areas and others): each station's elevation, distance and operator, its latest hourly
          reading (air temperature, humidity, wind and gusts, snow height, new snow) and a summary of the past hours (snow
          height change, new snow, minimum and maximum temperature, strongest gust). Stations measure different things,
          and many are on ridges or in alpine terrain, so compare elevations. Pass on safety_note.
        TEXT
        enabled_when("WEATHER_MCP_AVALANCHE", &:avalanche_enabled)
        location_arguments
        argument :radius_km, :integer, in: 1..MAX_RADIUS_KM, default: 30, description: "Search radius."
        argument :hours, :integer, in: 1..MAX_HOURS, default: 24, description: "Hours of readings to summarize."
        argument :limit, :integer, in: 1..MAX_STATIONS, default: 3, description: "Nearest stations to include."
        argument :lang, :language

        def call(args)
          point = args.point
          radius = args.radius_km
          hours = args.hours
          limit = args.limit
          stations = reporting_stations(nearest(point, radius, limit + SPARE_STATIONS), limit, hours)
          attribute(attribution_for("Mountain weather station data", stations.map { |station| station[:source] }))
          result = { location: point.to_h, stations:, safety_note: safety_note(args.lang) }
          result[:note] = "No Avalanche Canada weather station within #{radius} km has reported in the past #{hours} hours." if stations.empty?
          result
        end

        private

        def nearest(point, radius, count)
          avalanche.weather_stations.stations.filter_map do |station|
            next unless station.is_a?(Hash) && station["stationId"].is_a?(Integer) && station["stationId"].positive?

            lat = station["latitude"]
            lon = station["longitude"]
            next unless lat.is_a?(Numeric) && lon.is_a?(Numeric)

            distance = Geo.distance_km(point.lat, point.lon, lat, lon)
            [distance, station] if distance <= radius
          end.min_by(count, &:first)
        end

        # Stations without readings in the window (seasonal or broken) are skipped for the next nearest.
        def reporting_stations(candidates, limit, hours)
          to = Time.at((now.to_i + 3599) / 3600 * 3600).utc # the next full hour, so calls within an hour share a cache entry
          from = to - (hours * 3600)
          first_found(candidates, limit) { |distance, station| station(station, distance, from, to) }
        end

        def station(station, distance, from, to)
          info = { id: station["stationId"], name: station["name"], source: station["source"], elevation_m: number(station["elevation"]),
                   distance_km: round_km(distance), lat: number(station["latitude"]), lon: number(station["longitude"]) }
          readings = readings(avalanche.weather_stations.measurements(station["stationId"], from:, to:))
          return if readings.empty?

          newest = readings.first
          info[:note] = "The latest reading is more than #{STALE_AFTER / 3600} hours old." if now - newest[:at] > STALE_AFTER
          info.merge(latest: latest(newest), window: window(readings, from))
        rescue Sources::Error => e
          info.merge(note: "This station's readings could not be fetched: #{e.message}")
        end

        # Newest first, each with its time.
        def readings(measurements)
          readings = measurements.filter_map do |measurement|
            at = time(measurement["measurementDateTime"]) if measurement.is_a?(Hash)
            measurement.merge(at:) if at
          end
          readings.sort_by { |reading| -reading[:at].to_f }
        end

        def latest(reading)
          { observed_at: reading[:at], temperature_c: number(reading["airTempAvg"]),
            humidity_pct: number(reading["relativeHumidity"]), wind_speed_kmh: number(reading["windSpeedAvg"]),
            wind_direction: reading["windDirCompass"], wind_direction_deg: number(reading["windDirAvg"]),
            wind_gust_kmh: number(reading["windSpeedGust"]), wind_gust_direction: reading["windDirGustCompass"],
            snow_depth_cm: number(reading["snowHeight"]), new_snow_cm: number(reading["newSnow"]) }
        end

        def window(readings, from)
          heights = readings.filter_map { |reading| number(reading["snowHeight"]) }
          new_snow = readings.filter_map { |reading| number(reading["newSnow"]) }
          { from:, readings: readings.size,
            snow_depth_change_cm: ((heights.first - heights.last).round(1) if heights.size > 1),
            new_snow_cm: (new_snow.sum.round(1) if new_snow.any?),
            min_temperature_c: extreme(readings, "airTempMin", :min), max_temperature_c: extreme(readings, "airTempMax", :max),
            **max_gust(readings) }
        end

        def max_gust(readings)
          gust = readings.select { |reading| number(reading["windSpeedGust"]) }.max_by { |reading| reading["windSpeedGust"] }
          return {} unless gust

          { max_gust_kmh: gust["windSpeedGust"], max_gust_direction: gust["windDirGustCompass"], max_gust_at: gust[:at] }
        end

        # The hourly minimum or maximum where the station reports one, else its hourly mean.
        def extreme(readings, field, which)
          values = readings.filter_map { |reading| number(reading[field]) || number(reading["airTempAvg"]) }
          values.public_send(which) if values.any?
        end
      end
    end
  end
end
