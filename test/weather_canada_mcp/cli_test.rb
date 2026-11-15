# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

class CLITest < Minitest::Test
  BIN = File.join(TestHelpers::ROOT, "bin/weather-canada-mcp")

  # Runs bin/weather-canada-mcp with only the given settings, ignoring any in the developer's environment.
  def cli(*, **values)
    cleared = ENV.keys.grep(/\A(WEATHER_MCP|AVALANCHE_CANADA)_/).to_h { |key| [key, nil] }
    settings = { "WEATHER_MCP_GAZETTEER_PATH" => gazetteer_path, **values.transform_keys(&:to_s) }
    Open3.capture3(cleared.merge(settings), RbConfig.ruby, BIN, *)
  end

  def test_check_config_http
    stdout, _stderr, status = cli("check-config", WEATHER_MCP_AUTH_TOKEN: TestHelpers::AUTH_TOKEN)

    assert_predicate status, :success?
    assert_match(/Configuration OK for the http transport: #{WeatherCanadaMcp::Tools.all.size} tools enabled/, stdout)
    assert_match(/MCP authentication: bearer token/, stdout)
    assert_match(/Place-name database: #{Regexp.escape(gazetteer_path)}/, stdout)
  end

  def test_check_config_http_requires_a_token
    _stdout, stderr, status = cli("check-config", "http")

    assert_equal 78, status.exitstatus
    assert_match(/WEATHER_MCP_AUTH_TOKEN/, stderr)
  end

  def test_check_config_stdio_needs_no_token
    stdout, _stderr, status = cli("check-config", "stdio")

    assert_predicate status, :success?
    assert_match(/not used \(stdio\)/, stdout)
  end

  def test_check_config_warns_about_non_default_upstreams
    _stdout, stderr, status = cli("check-config", "stdio", WEATHER_MCP_API_URL: "http://127.0.0.1:9")

    assert_predicate status, :success?
    assert_match(%r{non_default_upstream upstream=api url=http://127\.0\.0\.1:9}, stderr)
  end

  def test_unknown_commands_and_transports
    assert_equal 64, cli("serve").last.exitstatus
    assert_equal 64, cli("check-config", "sse").last.exitstatus
  end

  def test_tools_prints_the_manifest
    stdout, _stderr, status = cli("tools")

    assert_predicate status, :success?
    assert_equal(WeatherCanadaMcp::Tools.all.map(&:tool_name), JSON.parse(stdout).map { |tool| tool["name"] })
  end

  def test_tool_manifest_matches_the_snapshot
    manifest = "#{JSON.pretty_generate(JSON.parse(JSON.generate(WeatherCanadaMcp::Tools.all.map(&:manifest))))}\n"
    path = File.join(TestHelpers::ROOT, "test/fixtures/tools.json")
    File.write(path, manifest) if ENV["UPDATE_SNAPSHOTS"]

    assert_equal File.read(path), manifest, "tool names, descriptions or schemas changed; review and run UPDATE_SNAPSHOTS=1 rake test"
  end

  def test_gazetteer_info
    stdout, _stderr, status = cli("gazetteer", "info")

    assert_predicate status, :success?
    assert_equal "1", JSON.parse(stdout)["schema_version"]
  end

  def test_version
    assert_equal "#{WeatherCanadaMcp::VERSION}\n", cli("version").first
  end
end
