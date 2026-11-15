# frozen_string_literal: true

require "uri"

module WeatherCanadaMcp
  # Server configuration from environment variables. Secrets can also be read from files
  # (`*_FILE`, e.g. Docker secrets). Invalid configuration fails at startup with every problem listed.
  class Config
    class Error < WeatherCanadaMcp::Error; end

    MIN_AUTH_TOKEN_LENGTH = 32
    LOG_LEVELS = %w[debug info warn error].freeze
    LOG_FORMATS = %w[text json].freeze
    LANGS = %w[en fr].freeze
    DEFAULT_CONTACT = "https://github.com/cloetzi/weather-canada-mcp"

    # ECCC and NRCan hosts. Each can be pointed at a local fake for tests (WEATHER_MCP_<NAME>_URL).
    UPSTREAMS = {
      api: "https://api.weather.gc.ca",
      datamart: "https://dd.weather.gc.ca",
      geomet: "https://geo.weather.gc.ca",
      cgn: "https://ftp.maps.canada.ca" # NRCan Canadian Geographical Names, for the gazetteer
    }.freeze
    # Avalanche Canada's forecast and mountain weather services: origins only when AVALANCHE_CANADA_ENABLED is true.
    AVALANCHE_UPSTREAMS = {
      avalanche: "https://avcan-services-api.prod.avalanche.ca",
      avalanche_weather: "https://weather.prod.avalanche.ca"
    }.freeze
    AVALANCHE_URL_VARIABLES = { avalanche: "AVALANCHE_CANADA_URL", avalanche_weather: "AVALANCHE_CANADA_WEATHER_URL" }.freeze
    DEFAULT_UPSTREAMS = UPSTREAMS.merge(AVALANCHE_UPSTREAMS).freeze

    ATTRIBUTES = %i[
      auth_tokens auth_disabled listen_address path allowed_hosts allowed_origins tools exclude_tools lang
      user_agent_contact cache_scale upstreams timeout max_concurrency requests_per_second max_response_bytes
      max_download_bytes gazetteer_path log_level log_format avalanche_canada_enabled avalanche_canada_field_reports_enabled
    ].freeze

    attr_reader(*ATTRIBUTES)

    # transport: :http requires MCP authentication settings; :stdio ignores them.
    # credentials: false skips the MCP tokens, for commands that never serve.
    def self.from_env(env = ENV, transport: :http, credentials: true) = new(env, transport, credentials).freeze

    def initialize(env, transport, credentials) # rubocop:disable Metrics/AbcSize -- one assignment per setting
      @reader = EnvReader.new(env)
      @errors = @reader.errors # Config's own checks add theirs here too, so validate! lists every problem
      @auth_disabled = boolean("WEATHER_MCP_AUTH_DISABLED", false)
      @auth_tokens = credentials && transport == :http ? auth_tokens_value : []
      @listen_address = Server::ListenAddress.read(@reader)
      @path = path_value
      @allowed_hosts = list("WEATHER_MCP_ALLOWED_HOSTS")
      @allowed_origins = list("WEATHER_MCP_ALLOWED_ORIGINS")
      @tools = string("WEATHER_MCP_TOOLS", nil) && list("WEATHER_MCP_TOOLS")
      @exclude_tools = list("WEATHER_MCP_EXCLUDE_TOOLS")
      @lang = choice("WEATHER_MCP_LANG", "en", LANGS)
      @user_agent_contact = contact_value
      @cache_scale = float("WEATHER_MCP_CACHE_SCALE", 1.0, 0.0..100.0)
      @avalanche_canada_enabled = boolean("AVALANCHE_CANADA_ENABLED", false)
      @avalanche_canada_field_reports_enabled = field_reports_value
      @upstreams = upstreams_value
      @timeout = integer("WEATHER_MCP_TIMEOUT", 20, 1..300)
      @max_concurrency = integer("WEATHER_MCP_MAX_CONCURRENCY", 4, 1..16)
      @requests_per_second = float("WEATHER_MCP_REQUESTS_PER_SECOND", 1.0, 0.1..10.0)
      @max_response_bytes = integer("WEATHER_MCP_MAX_RESPONSE_BYTES", 60_000, 1_000..10_000_000)
      @max_download_bytes = integer("WEATHER_MCP_MAX_DOWNLOAD_BYTES", 20 * 1024 * 1024, 1024..(512 * 1024 * 1024))
      @gazetteer_path = string("WEATHER_MCP_GAZETTEER_PATH", Places::Gazetteer.default_path)
      @log_level = choice("WEATHER_MCP_LOG_LEVEL", "info", LOG_LEVELS)
      @log_format = choice("WEATHER_MCP_LOG_FORMAT", "text", LOG_FORMATS)
      validate!
    end

    def user_agent = "weather-canada-mcp/#{VERSION} (+#{user_agent_contact})"

    def inspect = "#<#{self.class.name} listen=#{listen_address.authority} path=#{path} auth=#{auth_disabled ? "disabled" : "bearer"}>"

    private

    def string(...) = @reader.string(...)
    def list(...) = @reader.list(...)
    def integer(...) = @reader.integer(...)
    def float(...) = @reader.float(...)
    def boolean(...) = @reader.boolean(...)
    def choice(...) = @reader.choice(...)
    def secret(...) = @reader.secret(...)

    def validate!
      @reader.validate!
      remove_instance_variable(:@reader)
      remove_instance_variable(:@errors)
    end

    def auth_tokens_value
      raw = secret("WEATHER_MCP_AUTH_TOKEN")
      tokens = raw.to_s.split(/[\s,]+/).reject(&:empty?)
      if @auth_disabled
        @errors << "WEATHER_MCP_AUTH_DISABLED=true conflicts with WEATHER_MCP_AUTH_TOKEN; set only one" if tokens.any?
      elsif tokens.empty?
        @errors << "WEATHER_MCP_AUTH_TOKEN (or WEATHER_MCP_AUTH_TOKEN_FILE) is required; " \
                   "generate one with `openssl rand -hex 32`, or set WEATHER_MCP_AUTH_DISABLED=true to run without authentication"
      elsif tokens.any? { |token| token.length < MIN_AUTH_TOKEN_LENGTH }
        @errors << "WEATHER_MCP_AUTH_TOKEN values must be at least #{MIN_AUTH_TOKEN_LENGTH} characters"
      end
      tokens.freeze
    end

    def path_value
      value = string("WEATHER_MCP_PATH", "/mcp")
      if value == Server::HealthCheck::PATH
        @errors << "WEATHER_MCP_PATH cannot be #{Server::HealthCheck::PATH}, which serves health checks"
      elsif !value.match?(%r{\A/[A-Za-z0-9/_.~-]*\z})
        @errors << "WEATHER_MCP_PATH must start with / and contain only URL path characters"
      end
      value
    end

    # Goes into the User-Agent header, so ECCC can reach whoever runs the server; header-safe characters only.
    def contact_value
      value = string("WEATHER_MCP_USER_AGENT_CONTACT", DEFAULT_CONTACT)
      return value if value.match?(%r{\A[\w.@:/+~?=&%#-]{1,200}\z})

      @errors << "WEATHER_MCP_USER_AGENT_CONTACT must be a URL or email address without spaces"
      DEFAULT_CONTACT
    end

    # Avalanche Canada publishes no open licence, so its services are off unless enabled; field reports need both flags.
    def field_reports_value
      enabled = boolean("AVALANCHE_CANADA_FIELD_REPORTS_ENABLED", false)
      @errors << "AVALANCHE_CANADA_FIELD_REPORTS_ENABLED=true needs AVALANCHE_CANADA_ENABLED=true as well" if enabled && !@avalanche_canada_enabled
      enabled && @avalanche_canada_enabled
    end

    # The Avalanche Canada URLs are validated even when disabled, but only become origins once enabled.
    def upstreams_value
      eccc = UPSTREAMS.to_h { |name, default| [name, upstream_value("WEATHER_MCP_#{name.upcase}_URL", default)] }
      avalanche = AVALANCHE_UPSTREAMS.to_h { |name, default| [name, upstream_value(AVALANCHE_URL_VARIABLES.fetch(name), default)] }
      (@avalanche_canada_enabled ? eccc.merge(avalanche) : eccc).freeze
    end

    # Requests carry no credentials, so any http(s) origin is allowed (a local fake, a caching proxy, a mirror).
    def upstream_value(variable, default)
      value = string(variable, default).chomp("/")
      uri = URI(value)
      return value if %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

      @errors << "#{variable} must be an http or https URL without credentials, query or fragment"
      default
    rescue URI::InvalidURIError
      @errors << "#{variable} is not a valid URL"
      default
    end
  end
end
