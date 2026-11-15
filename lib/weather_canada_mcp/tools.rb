# frozen_string_literal: true

module WeatherCanadaMCP
  # The MCP tools, one class per file. ALL lists them in the order tools/list shows them.
  module Tools
    # A problem with the arguments the model can fix; shown to it as a tool error.
    class InvalidArguments < WeatherCanadaMCP::Error; end

    # What tools share: the upstream sources (avalanche is nil unless enabled), a cache for images, the locator, the
    # gazetteer, the configuration and a clock (Time.now).
    Context = Data.define(:ogc, :wms, :basemap, :images, :avalanche, :locator, :places, :config, :clock)

    # An image a tool returns beside its JSON (Tools::Runner sends it as MCP image content).
    Image = Data.define(:data, :mime_type)

    # The ECCC tools, always available.
    def self.all
      [FindLocation, GetForecast, GetAlerts, GetCurrentObservations, GetRiverConditions, GetAirQuality, GetSnowOutlook, GetMarineForecast,
       GetClimateContext, GetRadarMap]
    end

    # Opt-in: WEATHER_MCP_AVALANCHE, and WEATHER_MCP_AVALANCHE_REPORTS for field reports.
    def self.avalanche = [GetAvalancheForecast, GetAvalancheDangerOverview, GetMountainWeatherStations]
    def self.field_reports = [GetFieldReports]

    # The tools this configuration can serve, before WEATHER_MCP_TOOLS and WEATHER_MCP_EXCLUDE_TOOLS.
    def self.available(config)
      [*all, *(avalanche if config.avalanche_enabled), *(field_reports if config.avalanche_reports_enabled)]
    end
  end
end
