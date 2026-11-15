# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Which tools exist, in the order tools/list shows them, and which of them this configuration serves: a tool's own
    # `enabled_when` condition, then WEATHER_MCP_TOOLS and WEATHER_MCP_EXCLUDE_TOOLS.
    class Registry
      ALL = [
        FindLocation, GetForecast, GetAlerts, GetCurrentObservations, GetRiverConditions, GetAirQuality, GetSnowOutlook,
        GetMarineForecast, GetClimateContext, GetRadarMap,
        Avalanche::GetForecast, Avalanche::GetDangerOverview, Avalanche::GetMountainWeatherStations, Avalanche::GetFieldReports
      ].freeze

      # The tools that need no setting.
      def self.core = ALL.reject(&:conditional?)

      def initialize(config, all: ALL)
        @config = config
        @all = all
      end

      # The tools this configuration can serve, before WEATHER_MCP_TOOLS and WEATHER_MCP_EXCLUDE_TOOLS.
      def available = @all.select { |tool| tool.enabled?(@config) }

      def selected
        chosen = available.select { |tool| @config.tools.nil? || @config.tools.include?(tool.tool_name) }
        chosen.reject { |tool| @config.exclude_tools.include?(tool.tool_name) }
      end

      # WEATHER_MCP_TOOLS may name only tools this configuration serves; WEATHER_MCP_EXCLUDE_TOOLS any known tool, so
      # excluding an opt-in tool that is off does nothing.
      def unknown_names
        known = @all.map(&:tool_name)
        (Array(@config.tools) - available.map(&:tool_name)) | (@config.exclude_tools - known)
      end

      # Names the settings that switch on the opt-in tools among the unknown ones.
      def unknown_message
        unknown = unknown_names
        message = "unknown tools in WEATHER_MCP_TOOLS or WEATHER_MCP_EXCLUDE_TOOLS: #{unknown.join(", ")}"
        hints = @all.select { |tool| tool.conditional? && unknown.include?(tool.tool_name) }.group_by(&:setting)
        return message if hints.empty?

        "#{message} (#{hints.map { |setting, tools| "#{tools.map(&:tool_name).join(", ")} need #{setting}" }.join("; ")}; " \
          "see docs/configuration.md)"
      end
    end
  end
end
