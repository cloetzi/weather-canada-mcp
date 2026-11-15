# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

# Avalanche Canada publishes no open licence, so everything about it stays off unless configured.
class AvalancheOptInTest < Minitest::Test
  Config = WeatherCanadaMCP::Config
  AVALANCHE_TOOLS = %w[get_avalanche_forecast get_avalanche_danger_overview get_mountain_weather_stations].freeze

  def config(**) = Config.from_env(env(**))

  def tool_names(**values)
    app = application(nil, **values)
    app.mcp_server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list" }).dig(:result, :tools).map { |tool| tool[:name] }
  end

  def test_off_by_default
    defaults = config

    refute defaults.avalanche_enabled
    refute defaults.avalanche_reports_enabled
    assert_equal Config::UPSTREAMS, defaults.upstreams
    assert_equal WeatherCanadaMCP::Tools::Registry.core.map(&:tool_name), tool_names
  end

  def test_enabling_adds_the_origins_and_tools
    enabled = config(WEATHER_MCP_AVALANCHE: "true")

    assert_equal Config::DEFAULT_UPSTREAMS, enabled.upstreams
    assert_equal WeatherCanadaMCP::Tools::Registry.core.map(&:tool_name) + AVALANCHE_TOOLS, tool_names(WEATHER_MCP_AVALANCHE: "true")
  end

  def test_field_reports_have_their_own_flag
    names = tool_names(**AVALANCHE_ENABLED)

    assert_equal "get_field_reports", names.last
    refute_includes tool_names(WEATHER_MCP_AVALANCHE: "true"), "get_field_reports"
  end

  def test_field_reports_need_avalanche_enabled
    error = assert_raises(Config::Error) { config(WEATHER_MCP_AVALANCHE_REPORTS: "true") }

    assert_match(/WEATHER_MCP_AVALANCHE_REPORTS=true needs WEATHER_MCP_AVALANCHE=true/, error.message)
  end

  def test_urls_can_be_overridden_and_are_validated
    upstreams = config(WEATHER_MCP_AVALANCHE: "true", WEATHER_MCP_AVALANCHE_URL: "http://127.0.0.1:9/",
                       WEATHER_MCP_AVALANCHE_STATIONS_URL: "https://mirror.example/weather").upstreams

    assert_equal "http://127.0.0.1:9", upstreams[:avalanche]
    assert_equal "https://mirror.example/weather", upstreams[:avalanche_weather]
    assert_raises(Config::Error) { config(WEATHER_MCP_AVALANCHE_URL: "https://user:pw@example.com") }
  end

  def test_naming_an_avalanche_tool_without_the_flag_explains_why
    error = assert_raises(WeatherCanadaMCP::Error) { application(nil, WEATHER_MCP_TOOLS: "get_avalanche_forecast") }

    assert_match(/get_avalanche_forecast need WEATHER_MCP_AVALANCHE/, error.message)
  end

  def test_excluding_an_opt_in_tool_that_is_off_does_nothing
    names = tool_names(WEATHER_MCP_AVALANCHE: "true", WEATHER_MCP_EXCLUDE_TOOLS: "get_field_reports,get_avalanche_forecast")

    refute_includes names, "get_avalanche_forecast"
    assert_includes names, "get_mountain_weather_stations"
    assert_raises(WeatherCanadaMCP::Error) { application(nil, WEATHER_MCP_EXCLUDE_TOOLS: "get_weather") }
  end

  def test_instructions_mention_avalanche_canada_only_when_enabled
    refute_includes application(nil).mcp_server.instructions, "Avalanche Canada"
    assert_includes application(nil, WEATHER_MCP_AVALANCHE: "true").mcp_server.instructions, "Avalanche Canada"
  end

  def test_opt_in_tool_manifest_matches_the_snapshot
    tools = WeatherCanadaMCP::Tools::Registry::ALL - WeatherCanadaMCP::Tools::Registry.core
    manifest = "#{JSON.pretty_generate(JSON.parse(JSON.generate(tools.map(&:manifest))))}\n"
    path = File.join(TestHelpers::ROOT, "test/fixtures/tools_avalanche.json")
    File.write(path, manifest) if ENV["UPDATE_SNAPSHOTS"]

    assert_equal File.read(path, encoding: Encoding::UTF_8), manifest,
                 "tool names, descriptions or schemas changed; review and run UPDATE_SNAPSHOTS=1 rake test"
  end

  def test_the_tools_command_lists_them_once_enabled
    run = lambda do |**values|
      cleared = ENV.keys.grep(/\AWEATHER_MCP_/).to_h { |key| [key, nil] }
      stdout, _stderr, status = Open3.capture3(cleared.merge(values.transform_keys(&:to_s)), RbConfig.ruby,
                                               File.join(TestHelpers::ROOT, "bin/weather-canada-mcp"), "tools")

      assert_predicate status, :success?
      JSON.parse(stdout.force_encoding(Encoding::UTF_8)).map { |tool| tool["name"] }
    end

    refute_includes run.call, "get_avalanche_forecast"
    assert_includes run.call(**AVALANCHE_ENABLED), "get_field_reports"
  end

  def test_logs_never_hold_arguments_results_or_station_ids
    io = StringIO.new
    with_fake_eccc do |fake|
      fake.route("/stations/110/measurements") { [503, {}, "busy"] }
      app = application(fake, logger: WeatherCanadaMCP::Logger.new(io:, level: "debug"), clock: -> { AVALANCHE_CAPTURED_AT },
                              **AVALANCHE_ENABLED)
      call_tool(app, "get_avalanche_forecast", lat: 51.42, lon: -116.18)
      call_tool(app, "get_mountain_weather_stations", lat: 51.42, lon: -116.18)
      call_tool(app, "get_field_reports", lat: 50.41, lon: -116.5)
    ensure
      app&.close
    end
    log = io.string

    assert_includes log, "get_field_reports"
    assert_includes log, "/stations/{id}/measurements" # the retried request, without its id
    ["51.42", "116.18", "50.41", "Farnham", "Bosworth", "/stations/110", "Parks Canada"].each { |text| refute_includes log, text }
  end
end
