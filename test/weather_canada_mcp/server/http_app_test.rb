# frozen_string_literal: true

require_relative "../../test_helper"
require "rack/mock"

# Exercises the full stack below Falcon: Rack app, SDK transport, tools, upstream client (against the fake).
class HttpAppTest < Minitest::Test
  def app(fake, logger: null_logger, **values)
    @application = application(fake, logger:, **values)
    Rack::MockRequest.new(@application.rack_app)
  end

  def teardown = @application&.close

  def rpc(app, method, params = nil, token: TestHelpers::AUTH_TOKEN, host: "localhost:8080", **headers)
    body = JSON.generate({ jsonrpc: "2.0", id: 1, method:, params: }.compact)
    headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream",
                "HTTP_MCP_PROTOCOL_VERSION" => "2025-11-25", "HTTP_HOST" => host, **headers.transform_keys(&:to_s) }.compact
    headers["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    app.post("/mcp", input: body, **headers)
  end

  def result(response) = JSON.parse(response.body).fetch("result")

  def test_healthz_is_public
    with_fake_eccc do |fake|
      response = app(fake).get("/healthz")

      assert_equal 200, response.status
      assert_equal "ok", JSON.parse(response.body)["status"]
    end
  end

  def test_requires_bearer_token
    with_fake_eccc do |fake|
      app = app(fake)

      assert_equal 401, rpc(app, "tools/list", token: nil).status
      assert_equal 401, rpc(app, "tools/list", token: "x" * 40).status
      assert_match(/\ABearer/, rpc(app, "tools/list", token: nil).headers["www-authenticate"])
      assert_equal 200, rpc(app, "tools/list").status
    end
  end

  def test_auth_can_be_disabled
    with_fake_eccc do |fake|
      app = app(fake, WEATHER_MCP_AUTH_TOKEN: nil, WEATHER_MCP_AUTH_DISABLED: "true")

      assert_equal 200, rpc(app, "tools/list", token: nil).status
    end
  end

  def test_rejects_unknown_hosts_and_origins
    with_fake_eccc do |fake|
      app = app(fake, WEATHER_MCP_ALLOWED_HOSTS: "mcp.lan")

      assert_equal 403, rpc(app, "tools/list", host: "evil.example").status
      assert_equal 200, rpc(app, "tools/list", host: "mcp.lan:8080").status
      assert_equal 200, rpc(app, "tools/list", host: "[::1]:8080").status
      assert_equal 403, rpc(app, "tools/list", HTTP_ORIGIN: "https://evil.example").status
      assert_equal 200, rpc(app, "tools/list", HTTP_ORIGIN: "http://localhost:8080").status
      assert_equal 200, rpc(app, "tools/list", host: nil).status
    end
  end

  def test_wildcard_hosts_still_reject_foreign_origins
    with_fake_eccc do |fake|
      app = app(fake, WEATHER_MCP_ALLOWED_HOSTS: "*", WEATHER_MCP_ALLOWED_ORIGINS: "https://app.example",
                      WEATHER_MCP_AUTH_TOKEN: nil, WEATHER_MCP_AUTH_DISABLED: "true")

      assert_equal 200, rpc(app, "tools/list", token: nil, host: "mcp.example").status
      assert_equal 403, rpc(app, "tools/list", token: nil, host: "mcp.example", HTTP_ORIGIN: "https://evil.example").status
      assert_equal 200, rpc(app, "tools/list", token: nil, host: "mcp.example", HTTP_ORIGIN: "https://app.example").status
    end
  end

  def test_rejections_are_logged_with_a_hint
    with_fake_eccc do |fake|
      io = StringIO.new
      app = app(fake, logger: WeatherCanadaMCP::Logger.new(io:, level: "warn"))

      assert_equal "host not allowed", JSON.parse(rpc(app, "tools/list", host: "evil.example").body)["error"]
      assert_equal "origin not allowed", JSON.parse(rpc(app, "tools/list", HTTP_ORIGIN: "https://evil.example").body)["error"]
      assert_match(/host_rejected host=evil.example hint="add the host to WEATHER_MCP_ALLOWED_HOSTS"/, io.string)
      assert_match(%r{origin_rejected origin=https://evil.example hint="add the origin to WEATHER_MCP_ALLOWED_ORIGINS"}, io.string)
      refute_includes io.string, TestHelpers::AUTH_TOKEN
    end
  end

  def test_health_checks_are_logged_only_at_debug
    with_fake_eccc do |fake|
      io = StringIO.new
      app = app(fake, logger: WeatherCanadaMCP::Logger.new(io:, level: "info"))
      app.get("/healthz")
      app.get("/missing")

      refute_includes io.string, "path=/healthz"
      assert_includes io.string, "path=/missing"
    end
  end

  def test_initialize_advertises_tools_and_instructions
    with_fake_eccc do |fake|
      init = result(rpc(app(fake), "initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } }))

      assert_equal({ "tools" => {} }, init["capabilities"])
      assert_match(/Environment and Climate Change Canada/, init["instructions"])
    end
  end

  def test_tools_list_honors_filters
    with_fake_eccc do |fake|
      tools = result(rpc(app(fake, WEATHER_MCP_EXCLUDE_TOOLS: "find_location"), "tools/list"))["tools"]

      assert_equal WeatherCanadaMCP::Tools.core.map(&:tool_name).sort - ["find_location"], tools.map { |tool| tool["name"] }.sort
      assert(tools.all? { |tool| tool.dig("annotations", "readOnlyHint") })
    end
  end

  def test_tool_call_over_http
    with_fake_eccc do |fake|
      response = result(rpc(app(fake), "tools/call", { name: "get_alerts", arguments: { lat: 53.54, lon: -113.49 } }))
      data = JSON.parse(response.dig("content", 0, "text"))

      refute response["isError"]
      assert_equal "FGA", data.dig("alerts", 0, "code")
    end
  end

  def test_invalid_arguments_are_tool_errors
    with_fake_eccc do |fake|
      app = app(fake)
      unknown_argument = result(rpc(app, "tools/call", { name: "get_forecast", arguments: { lat: 49.7, lon: -123.15, extra: 1 } }))
      out_of_range = result(rpc(app, "tools/call", { name: "get_forecast", arguments: { lat: 49.7, lon: -123.15, hours: 999 } }))

      assert unknown_argument["isError"]
      assert out_of_range["isError"]
      assert_empty fake.requests
    end
  end
end
