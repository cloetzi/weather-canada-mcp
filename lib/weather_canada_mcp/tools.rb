# frozen_string_literal: true

module WeatherCanadaMcp
  # The MCP tools, one class per file. ALL lists them in the order tools/list shows them.
  module Tools
    # A problem with the arguments the model can fix; shown to it as a tool error.
    class InvalidArguments < WeatherCanadaMcp::Error; end

    # What tools share: the upstream sources, the locator, the gazetteer, the configuration and a clock (Time.now).
    Context = Data.define(:ogc, :wms, :basemap, :locator, :places, :config, :clock)

    # An image a tool returns beside its JSON (Tools::Runner sends it as MCP image content).
    Image = Data.define(:data, :mime_type)

    def self.all
      [FindLocation, GetForecast, GetAlerts, GetCurrentObservations, GetRiverConditions, GetAirQuality, GetSnowOutlook, GetMarineForecast,
       GetClimateContext, GetRadarMap]
    end
  end
end
