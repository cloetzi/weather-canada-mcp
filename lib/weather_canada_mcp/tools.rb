# frozen_string_literal: true

module WeatherCanadaMcp
  # The MCP tools, one class per file. ALL lists them in the order tools/list shows them.
  module Tools
    # A problem with the arguments the model can fix; shown to it as a tool error.
    class InvalidArguments < WeatherCanadaMcp::Error; end

    # What tools share: the upstream sources, the locator, the gazetteer, the configuration and a clock (Time.now).
    Context = Data.define(:ogc, :wms, :locator, :places, :config, :clock)

    def self.all = [FindLocation, GetForecast, GetAlerts, GetCurrentObservations, GetRiverConditions, GetAirQuality, GetSnowOutlook]
  end
end
