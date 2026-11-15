# frozen_string_literal: true

module WeatherCanadaMCP
  # The MCP tools, one class per file. `core` lists the ECCC tools in the order tools/list shows them.
  module Tools
    # A problem with the arguments the model can fix; shown to it as a tool error.
    class InvalidArguments < WeatherCanadaMCP::Error; end

    # What tools share: the upstream sources (avalanche is nil unless enabled), a cache for images, the forecast sites,
    # the gazetteer, the configuration and a clock (Time.now).
    Context = Data.define(:ogc, :wms, :basemap, :image_cache, :avalanche, :forecast_sites, :gazetteer, :config, :clock)

    # An image a tool returns beside its JSON (Tools::Runner sends it as MCP image content).
    Image = Data.define(:data, :mime_type)

    # The ECCC tools, always available.
    def self.core
      [FindLocation, GetForecast, GetAlerts, GetCurrentObservations, GetRiverConditions, GetAirQuality, GetSnowOutlook, GetMarineForecast,
       GetClimateContext, GetRadarMap]
    end

    # Opt-in: WEATHER_MCP_AVALANCHE, and WEATHER_MCP_AVALANCHE_REPORTS for field reports.
    def self.avalanche = [Avalanche::GetForecast, Avalanche::GetDangerOverview, Avalanche::GetMountainWeatherStations]
    def self.field_reports = [Avalanche::GetFieldReports]

    # The tools this configuration can serve, before WEATHER_MCP_TOOLS and WEATHER_MCP_EXCLUDE_TOOLS.
    def self.available(config)
      [*core, *(avalanche if config.avalanche_enabled), *(field_reports if config.avalanche_reports_enabled)]
    end
  end
end
