# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "time"
require_relative "../lib/weather_canada_mcp"
require_relative "support/fake_eccc"

Warning[:experimental] = false

module TestHelpers
  ROOT = File.expand_path("..", __dir__)
  AUTH_TOKEN = "t" * 40
  # When the fixtures were captured: alerts in them are active at this time.
  CAPTURED_AT = Time.utc(2026, 11, 15, 17, 0, 0)

  def null_logger = WeatherCanadaMcp::Logger.new(io: StringIO.new, level: "error")

  # Runs the block inside a reactor with a fake upstream, which is stopped afterwards.
  def with_fake_eccc
    Sync do |task|
      fake = FakeEccc.new.start(task)
      yield fake
    ensure
      fake&.stop
    end
  end

  # The gazetteer built once per test run from the real CGN sample.
  def self.gazetteer_path
    @gazetteer_path ||= begin
      path = File.join(Dir.mktmpdir("gazetteer"), "gazetteer.sqlite3")
      File.open(File.join(ROOT, "test/fixtures/cgn/cgn_sample.csv"), encoding: "bom|utf-8") do |csv|
        WeatherCanadaMcp::Gazetteer::Builder.new(logger: WeatherCanadaMcp::Logger.new(io: StringIO.new)).build(csv, path, source: "test")
      end
      path
    end
  end

  def gazetteer_path = TestHelpers.gazetteer_path

  # Every upstream points at the fake; requests are not rate limited.
  def env(fake = nil, **overrides)
    upstreams = fake ? %w[API DATAMART GEOMET CGN].to_h { |name| ["WEATHER_MCP_#{name}_URL", fake.url] } : {}
    {
      "WEATHER_MCP_AUTH_TOKEN" => AUTH_TOKEN,
      "WEATHER_MCP_GAZETTEER_PATH" => gazetteer_path,
      "WEATHER_MCP_REQUESTS_PER_SECOND" => "10",
      **upstreams
    }.merge(overrides.transform_keys(&:to_s)).compact
  end

  def application(fake, logger: null_logger, clock: -> { CAPTURED_AT }, transport: :http, **values)
    WeatherCanadaMcp::Application.new(WeatherCanadaMcp::Config.from_env(env(fake, **values), transport:), logger:, clock:)
  end

  # Calls a tool through the MCP server and returns [parsed JSON or text, error?].
  def call_tool(app, name, **arguments)
    response = app.mcp_server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } })
    result = response.fetch(:result) { flunk("protocol error: #{response.inspect}") }
    text = result[:content].first[:text]
    [result[:isError] ? text : JSON.parse(text), result[:isError]]
  end

  def write_tempfile(name, content)
    path = File.join(Dir.mktmpdir, name)
    File.write(path, content)
    path
  end
end

Minitest::Test.include(TestHelpers)
