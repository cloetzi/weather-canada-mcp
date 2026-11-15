# frozen_string_literal: true

require "mcp"

module WeatherCanadaMcp
  # Wires configuration, upstream client, cache, sources, gazetteer and tools into an MCP server.
  class Application
    SERVER_NAME = "weather-canada"
    INSTRUCTIONS = <<~TEXT.tr("\n", " ").strip
      Weather, alerts and outdoor conditions for Canada from Environment and Climate Change Canada (ECCC) open data.
      Tools take a Canadian place name (location) or lat/lon. Use find_location when a name is ambiguous. Results
      name the forecast site or station used and its distance: say so when it is far from the place asked about.
      Quote alert text as given. Times are UTC. This is an unofficial tool; for safety-critical decisions point
      people to weather.gc.ca.
    TEXT
    IMAGE_CACHE_ENTRIES = 64
    AVALANCHE_INSTRUCTIONS = <<~TEXT.tr("\n", " ").strip
      The avalanche tools use Avalanche Canada data: report danger ratings exactly as given, quote forecast text rather
      than reword it, and always pass on the safety note and the official forecast link.
    TEXT

    attr_reader :config, :logger, :tools

    def self.tool_classes(config)
      selected = Tools.available(config).select { |tool| config.tools.nil? || config.tools.include?(tool.tool_name) }
      selected.reject { |tool| config.exclude_tools.include?(tool.tool_name) }
    end

    # WEATHER_MCP_TOOLS may name only tools this configuration serves; WEATHER_MCP_EXCLUDE_TOOLS any known tool, so
    # excluding an opt-in tool that is off does nothing.
    def self.unknown_tools(config)
      known = (Tools.all + Tools.avalanche + Tools.field_reports).map(&:tool_name)
      (Array(config.tools) - Tools.available(config).map(&:tool_name)) | (config.exclude_tools - known)
    end

    def self.unknown_tools_message(unknown)
      message = "unknown tools in WEATHER_MCP_TOOLS or WEATHER_MCP_EXCLUDE_TOOLS: #{unknown.join(", ")}"
      opt_in = (Tools.avalanche + Tools.field_reports).map(&:tool_name) & unknown
      opt_in.any? ? "#{message} (#{opt_in.join(", ")} need AVALANCHE_CANADA_ENABLED; see docs/configuration.md)" : message
    end

    def initialize(config, logger: Logger.new(level: config.log_level, format: config.log_format), clock: -> { Time.now })
      @config = config
      @logger = logger
      @clock = clock
      unknown = self.class.unknown_tools(config)
      raise Error, self.class.unknown_tools_message(unknown) if unknown.any?

      @tools = self.class.tool_classes(config)
      raise Error, "no tools are enabled; check WEATHER_MCP_TOOLS and WEATHER_MCP_EXCLUDE_TOOLS" if tools.empty?
    end

    def http
      @http ||= Sources::HttpClient.new(
        origins: config.upstreams, user_agent: config.user_agent, timeout: config.timeout,
        max_concurrency: config.max_concurrency, max_body_bytes: config.max_download_bytes,
        rate_limiter: Sources::RateLimiter.new(rate: config.requests_per_second, burst: 4), logger:
      )
    end

    def cache = @cache ||= Sources::Cache.new(scale: config.cache_scale)

    # Map images (100 KB or more each) are kept apart, so they never crowd out the small entries.
    def image_cache = @image_cache ||= Sources::Cache.new(max_entries: IMAGE_CACHE_ENTRIES, scale: config.cache_scale)

    def ogc = @ogc ||= Sources::OgcApi.new(http:, cache:)

    def wms = @wms ||= Sources::Wms.new(http:, cache:, image_cache:)

    def basemap = @basemap ||= Sources::Basemap.new(http:, cache: image_cache)

    def avalanche = (@avalanche ||= Sources::AvalancheCanada.new(http:, cache:) if config.avalanche_canada_enabled)

    def places = @places ||= Places::Gazetteer::Provider.new(path: config.gazetteer_path, http:, logger:)

    def context
      @context ||= Tools::Context.new(ogc:, wms:, basemap:, images: image_cache, avalanche:, locator: Places::Locator.new(ogc:),
                                      places:, config:, clock: @clock)
    end

    def instructions = config.avalanche_canada_enabled ? "#{INSTRUCTIONS} #{AVALANCHE_INSTRUCTIONS}" : INSTRUCTIONS

    # A fresh MCP server per transport; the SDK binds one transport to one server.
    def mcp_server
      runner = Tools::Runner.new(context:, logger:, max_response_bytes: config.max_response_bytes)
      MCP::Server.new(
        name: SERVER_NAME,
        title: "Weather Canada (unofficial)",
        version: VERSION,
        instructions:,
        tools: tools.map { |tool| runner.mcp_tool(tool) },
        capabilities: { tools: {} },
        configuration: MCP::Configuration.new(exception_reporter: Server::ExceptionReporter.new(logger))
      )
    end

    def rack_app = Server::HttpApp.new(server: mcp_server, config:, logger:)

    def close
      @places&.close
      @http&.close
    end
  end
end
