# frozen_string_literal: true

require_relative "../test_helper"

class ConfigTest < Minitest::Test
  Config = WeatherCanadaMCP::Config

  def config(transport: :http, **values) = Config.from_env(env(**values), transport:)

  def assert_config_error(pattern, transport: :http, **values)
    error = assert_raises(Config::Error) { config(transport:, **values) }
    assert_match pattern, error.message
  end

  def test_defaults
    config = Config.from_env({ "WEATHER_MCP_AUTH_TOKEN" => TestHelpers::AUTH_TOKEN })

    assert_equal Config::UPSTREAMS, config.upstreams
    assert_equal WeatherCanadaMCP::Config::ListenAddress.new(host: "127.0.0.1", port: 8080), config.listen_address
    assert_equal "/mcp", config.path
    assert_equal "en", config.lang
    assert_in_delta 1.0, config.requests_per_second
    assert_nil config.tools
    assert_equal "weather-canada-mcp/#{WeatherCanadaMCP::VERSION} (+https://github.com/cloetzi/weather-canada-mcp)", config.user_agent
  end

  def test_auth_token_is_required_for_http
    assert_config_error(/WEATHER_MCP_AUTH_TOKEN .* is required/, WEATHER_MCP_AUTH_TOKEN: nil)
  end

  def test_auth_can_be_disabled_explicitly
    config = config(WEATHER_MCP_AUTH_TOKEN: nil, WEATHER_MCP_AUTH_DISABLED: "true")

    assert config.auth_disabled
    assert_empty config.auth_tokens
  end

  def test_auth_disabled_and_token_conflict
    assert_config_error(/conflicts/, WEATHER_MCP_AUTH_DISABLED: "true")
  end

  def test_short_tokens_are_rejected
    assert_config_error(/at least 32 characters/, WEATHER_MCP_AUTH_TOKEN: "short")
  end

  def test_token_from_file
    path = write_tempfile("token", "#{"f" * 40}\n")

    assert_equal ["f" * 40], config(WEATHER_MCP_AUTH_TOKEN: nil, WEATHER_MCP_AUTH_TOKEN_FILE: path).auth_tokens
  end

  def test_stdio_needs_no_auth_token
    assert_empty config(transport: :stdio, WEATHER_MCP_AUTH_TOKEN: nil).auth_tokens
  end

  def test_upstreams_can_point_at_any_http_origin
    config = config(WEATHER_MCP_ECCC_API_URL: "http://127.0.0.1:9/", WEATHER_MCP_CGN_URL: "https://mirror.example/cgn")

    assert_equal "http://127.0.0.1:9", config.upstreams[:eccc_api]
    assert_equal "https://mirror.example/cgn", config.upstreams[:cgn]
  end

  def test_upstreams_reject_credentials_queries_and_other_schemes
    ["ftp://example.com", "https://user:pw@example.com", "https://example.com/?a=1", "https://example.com/#x", "not a url"].each do |value|
      error = assert_raises(Config::Error, value) { config(WEATHER_MCP_ECCC_API_URL: value) }

      assert_match(/WEATHER_MCP_ECCC_API_URL/, error.message)
      refute_includes error.message, "pw@", value
    end
  end

  def test_user_agent_contact
    assert_equal "weather-canada-mcp/#{WeatherCanadaMCP::VERSION} (+ops@example.com)",
                 config(WEATHER_MCP_USER_AGENT_CONTACT: "ops@example.com").user_agent
    assert_config_error(/USER_AGENT_CONTACT/, WEATHER_MCP_USER_AGENT_CONTACT: "a b\r\nX-Evil: 1")
  end

  def test_lists_every_problem_at_once
    error = assert_raises(Config::Error) { config(WEATHER_MCP_PORT: "x", WEATHER_MCP_LOG_LEVEL: "loud", WEATHER_MCP_LANG: "de") }

    assert_match(/WEATHER_MCP_PORT/, error.message)
    assert_match(/WEATHER_MCP_LOG_LEVEL/, error.message)
    assert_match(/WEATHER_MCP_LANG/, error.message)
  end

  def test_tool_lists
    config = config(WEATHER_MCP_TOOLS: "get_forecast, get_alerts", WEATHER_MCP_ALLOWED_HOSTS: "mcp.lan,")

    assert_equal %w[get_forecast get_alerts], config.tools
    assert_equal %w[mcp.lan], config.allowed_hosts
  end

  def test_unknown_tools_fail_at_startup
    error = assert_raises(WeatherCanadaMCP::Error) { application(nil, WEATHER_MCP_TOOLS: "get_weather") }

    assert_match(/unknown tools .*get_weather/, error.message)
  end

  def test_inspect_hides_secrets
    refute_includes config.inspect, TestHelpers::AUTH_TOKEN
  end
end
