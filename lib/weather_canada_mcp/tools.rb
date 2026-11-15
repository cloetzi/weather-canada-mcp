# frozen_string_literal: true

module WeatherCanadaMcp
  # The MCP tools, one class per file. ALL lists them in the order tools/list shows them.
  module Tools
    # A problem with the arguments the model can fix; shown to it as a tool error.
    class InvalidArguments < WeatherCanadaMcp::Error; end

    # What tools share: the upstream sources (avalanche is nil unless enabled), the locator, the gazetteer, the
    # configuration and a clock (Time.now).
    Context = Data.define(:ogc, :avalanche, :locator, :places, :config, :clock)

    # The ECCC tools, always available.
    def self.all = [FindLocation, GetForecast, GetAlerts, GetCurrentObservations, GetRiverConditions, GetAirQuality]

    # Opt-in: AVALANCHE_CANADA_ENABLED, and AVALANCHE_CANADA_FIELD_REPORTS_ENABLED for field reports.
    def self.avalanche = [GetAvalancheForecast, GetAvalancheDangerOverview, GetMountainWeatherStations]
    def self.field_reports = [GetFieldReports]

    # The tools this configuration can serve, before WEATHER_MCP_TOOLS and WEATHER_MCP_EXCLUDE_TOOLS.
    def self.available(config)
      [*all, *(avalanche if config.avalanche_canada_enabled), *(field_reports if config.avalanche_canada_field_reports_enabled)]
    end
  end
end
