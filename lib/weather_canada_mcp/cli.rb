# frozen_string_literal: true

require "async"
require "json"

module WeatherCanadaMCP
  # Entry point for bin/weather-canada-mcp.
  class CLI
    USAGE = <<~TEXT
      Usage: weather-canada-mcp [command]

      Commands:
        http          Serve MCP over Streamable HTTP (default)
        stdio         Serve MCP over stdin/stdout
        check-config [http|stdio]
                      Validate configuration for a transport (default http), then exit
        tools         Print every tool this configuration can serve (including ones WEATHER_MCP_TOOLS hides) as JSON
        gazetteer update
                      Download NRCan's Canadian Geographical Names and (re)build the place-name database
        gazetteer info
                      Show where the place-name database is and what it holds
        version       Print the version

      Configuration is read from environment variables; see docs/configuration.md.
    TEXT

    def self.start(argv) = new.run(argv)

    def run(argv) # rubocop:disable Metrics/CyclomaticComplexity -- one branch per command
      command = argv.first || "http"
      case command
      when "http" then serve_http
      when "stdio" then serve_stdio
      when "check-config" then check_config(argv[1] || "http")
      when "tools" then puts JSON.pretty_generate(Tools::Registry.new(Config.from_env(credentials: false)).available.map(&:manifest))
      when "gazetteer" then gazetteer(argv[1])
      when "version", "--version", "-v" then puts VERSION
      when "help", "--help", "-h" then puts USAGE
      else usage_error("unknown command: #{command}")
      end
    rescue WeatherCanadaMCP::Error => e
      warn "weather-canada-mcp: #{e.message}"
      exit 78
    end

    private

    def usage_error(message)
      warn "#{message}\n\n#{USAGE}"
      exit 64
    end

    def serve_http
      require "falcon"

      app = boot(:http)
      config = app.config
      warn_insecure(app)
      endpoint = Async::HTTP::Endpoint.parse(config.listen_address.url)
      middleware = Falcon::Server.rack_middleware(app.rack_app, cache: false)

      with_shutdown(app) do
        Sync do
          task = Falcon::Server.new(middleware, endpoint).run
          app.logger.info("listening", url: config.listen_address.url(config.path), tools: app.tools.size,
                                       auth: config.auth_disabled ? "disabled" : "bearer")
          task.wait
        end
      end
    end

    def serve_stdio
      app = boot(:stdio)
      transport = MCP::Server::Transports::StdioTransport.new(app.mcp_server)
      app.logger.info("stdio_ready", tools: app.tools.size)
      with_shutdown(app) { Sync { transport.open } }
    end

    def check_config(transport)
      usage_error("unknown transport: #{transport}") unless %w[http stdio].include?(transport)

      app = boot(transport.to_sym)
      config = app.config
      puts "Configuration OK for the #{transport} transport: #{app.tools.size} tools enabled (#{app.tools.map(&:tool_name).join(", ")})"
      puts "MCP authentication: #{auth_summary(transport, config)}"
      built = app.gazetteer.available? ? config.gazetteer_path : "not built yet (built on first use, or run `gazetteer update`)"
      puts "Place-name database: #{built}"
    end

    def auth_summary(transport, config)
      return "not used (stdio)" if transport == "stdio"

      config.auth_disabled ? "DISABLED" : "bearer token"
    end

    def gazetteer(subcommand)
      config = Config.from_env(credentials: false)
      app = Application.new(config)
      case subcommand
      when "update"
        Sync { app.gazetteer.rebuild! }
        puts "Built #{config.gazetteer_path} (#{app.gazetteer.open.size} names)."
      when "info"
        return puts("No place-name database at #{config.gazetteer_path}.") unless app.gazetteer.available?

        puts JSON.pretty_generate(app.gazetteer.open.meta.merge("path" => config.gazetteer_path))
      else usage_error("unknown gazetteer command: #{subcommand.inspect}")
      end
    ensure
      app&.close
    end

    # Load all code up front so nothing autoloads inside request fibers and load errors surface at startup.
    def boot(transport)
      Zeitwerk::Loader.eager_load_namespace(WeatherCanadaMCP)
      Application.new(Config.from_env(transport:)).tap { |app| warn_upstreams(app) }
    end

    def warn_upstreams(app)
      app.config.upstreams.each do |name, url|
        next if url == Config::DEFAULT_UPSTREAMS[name]

        app.logger.warn("non_default_upstream", upstream: name, url:, message: "requests go to this URL instead of the official service")
      end
    end

    def warn_insecure(app)
      return unless app.config.auth_disabled

      app.logger.warn("auth_disabled", message: "MCP authentication is disabled; anyone who can reach this port can use the server")
    end

    def with_shutdown(app)
      Signal.trap("TERM") { raise Interrupt }
      yield
    rescue Interrupt
      app.logger.info("shutdown")
    ensure
      app.close
    end
  end
end
