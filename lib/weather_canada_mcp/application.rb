# frozen_string_literal: true

require "mcp"

module WeatherCanadaMCP
  # Wires configuration, upstream client, cache, sources, gazetteer and tools into an MCP server.
  class Application
    SERVER_NAME = "weather-canada"
    INSTRUCTIONS = <<~TEXT.tr("\n", " ").strip
      Weather, alerts and outdoor conditions for Canada from Environment and Climate Change Canada (ECCC) open data.
      Tools take a Canadian place name (location) or lat/lon. Use find_location when a name is ambiguous. Results
      name the forecast site or station used and its distance: say so when it is far from the place asked about.
      Quote alert text as given. Times are local to the place asked about, with their UTC offset. This is an unofficial tool; for safety-critical decisions point
      people to weather.gc.ca.
    TEXT
    IMAGE_CACHE_ENTRIES = 64
    CACHE_BYTES = 64 * 1024 * 1024
    IMAGE_CACHE_BYTES = 32 * 1024 * 1024
    COMPOSE_SLOTS = 2
    AVALANCHE_INSTRUCTIONS = <<~TEXT.tr("\n", " ").strip
      The avalanche tools use Avalanche Canada data: report danger ratings exactly as given, quote forecast text rather
      than reword it, and always pass on the safety note and the official forecast link.
    TEXT

    attr_reader :config, :logger, :tools

    def initialize(config, logger: Logger.new(level: config.log_level, format: config.log_format), clock: -> { Time.now }, rate_limiters: nil)
      @config = config
      @logger = logger
      @clock = clock
      @rate_limiters = rate_limiters
      registry = Tools::Registry.new(config)
      raise Error, registry.unknown_message if registry.unknown_names.any?

      @tools = registry.selected
      raise Error, "no tools are enabled; check WEATHER_MCP_TOOLS and WEATHER_MCP_EXCLUDE_TOOLS" if tools.empty?
    end

    def http
      @http ||= Sources::HttpClient.new(
        origins: config.upstreams, user_agent: config.user_agent, timeout: config.timeout,
        max_concurrency: config.max_concurrency, max_body_bytes: config.max_download_bytes,
        rate_limiters: @rate_limiters || Sources::RateLimiters.new(rate: config.requests_per_second), logger:
      )
    end

    def cache = @cache ||= Sources::Cache.new(max_bytes: CACHE_BYTES, scale: config.cache_scale, wall_clock: @clock)

    # Map images (100 KB or more each) are kept apart, so they never crowd out the small entries.
    def image_cache
      @image_cache ||= Sources::Cache.new(max_entries: IMAGE_CACHE_ENTRIES, max_bytes: IMAGE_CACHE_BYTES, scale: config.cache_scale,
                                          wall_clock: @clock)
    end

    def ogc = @ogc ||= Sources::ECCC::OgcApi.new(http:, cache:, logger:)

    def wms = @wms ||= Sources::Wms.new(http:, origin: :geomet, path: "/geomet", cache:, image_cache:)

    def basemap = @basemap ||= Sources::NRCan::Basemap.build(http:, cache: image_cache)

    def avalanche = (@avalanche ||= Sources::AvalancheCanada::Services.build(http:, cache:) if config.avalanche_enabled)

    def gazetteer = @gazetteer ||= Places::Gazetteer::Store.new(path: config.gazetteer_path, http:, logger:)

    def context
      @context ||= Tools::Context.new(ogc:, wms:, basemap:, image_cache:, avalanche:,
                                      forecast_sites: Sources::ECCC::ForecastSites.new(ogc:),
                                      stations: Sources::ECCC::Stations.build(ogc:), gazetteer:, config:, clock: @clock,
                                      compose_slots: Async::Semaphore.new(COMPOSE_SLOTS))
    end

    def instructions = config.avalanche_enabled ? "#{INSTRUCTIONS} #{AVALANCHE_INSTRUCTIONS}" : INSTRUCTIONS

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
      @gazetteer&.close
      @http&.close
    end
  end
end
