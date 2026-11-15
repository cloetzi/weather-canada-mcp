# frozen_string_literal: true

require "time"
require "uri"

module WeatherCanadaMCP
  module Sources
    module AvalancheCanada
      # Avalanche Canada's mountain weather stations and their hourly measurements.
      class WeatherStations < Client
        # Seconds, before WEATHER_MCP_CACHE_SCALE.
        TTLS = { stations: 86_400, measurements: 600 }.freeze

        def stations = get(:avalanche_weather, "/stations", TTLS[:stations], Array)

        # Hourly measurements between two times, newest first.
        def measurements(station_id, from:, to:)
          raise ArgumentError, "invalid station id" unless station_id.is_a?(Integer) && station_id.positive?

          query = URI.encode_www_form(fromDate: from.utc.iso8601, toDate: to.utc.iso8601)
          get(:avalanche_weather, "/stations/#{station_id}/measurements?#{query}", TTLS[:measurements], Array)
        end
      end
    end
  end
end
