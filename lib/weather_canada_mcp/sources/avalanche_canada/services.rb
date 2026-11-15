# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    module AvalancheCanada
      # The three Avalanche Canada clients, handed to the tools as `context.avalanche`.
      Services = Data.define(:forecasts, :weather_stations, :field_reports) do
        def self.build(http:, cache:)
          new(forecasts: Forecasts.new(http:, cache:), weather_stations: WeatherStations.new(http:, cache:),
              field_reports: FieldReports.new(http:, cache:))
        end
      end
    end
  end
end
