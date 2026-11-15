# frozen_string_literal: true

require_relative "../../test_helper"

class ExceptionReporterTest < Minitest::Test
  SECRET = "s3cr3t-token-and-home-address-142"

  def setup
    @io = StringIO.new
    @reporter = WeatherCanadaMCP::Server::ExceptionReporter.new(WeatherCanadaMCP::Logger.new(io: @io, format: "json"))
  end

  def logged = JSON.parse(@io.string.lines.last)

  def tool_call(name = "get_forecast", **arguments) = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }

  def test_logs_neither_the_message_nor_the_request
    @reporter.call(JSON::ParserError.new("unexpected token at '{\"token\":\"#{SECRET}\"'"), { request: tool_call(note: SECRET) })

    refute_includes @io.string, SECRET
    assert_equal({ "level" => "error", "msg" => "unhandled_exception", "error" => "JSON::ParserError",
                   "method" => "tools/call", "tool" => "get_forecast" }, logged.except("time"))
  end

  def test_reads_the_method_from_raw_json_and_string_keys
    @reporter.call(ArgumentError.new(SECRET), { request: JSON.generate(tool_call(note: SECRET)) })

    refute_includes @io.string, SECRET
    assert_equal %w[tools/call get_forecast], logged.values_at("method", "tool")
  end

  def test_drops_values_that_are_not_identifiers
    @reporter.call(RuntimeError.new(SECRET), { request: { "method" => "tools/call #{SECRET}" }, session_id: SECRET })

    refute_includes @io.string, SECRET
    refute logged.key?("method")
  end

  def test_logs_the_notification_label
    @reporter.call(IOError.new(SECRET), { notification: "tools_list_changed" })

    assert_equal "tools_list_changed", logged["notification"]
  end

  def test_logs_the_first_frame_in_lib
    error = assert_raises(KeyError) { WeatherCanadaMCP::Logger.new(level: SECRET) }
    @reporter.call(error, {})

    refute_includes @io.string, SECRET
    assert_match %r{\Alib/weather_canada_mcp/logger\.rb:\d+\z}, logged["location"]
  end

  def test_survives_unexpected_context
    @reporter.call(RuntimeError.new(SECRET), "not a hash")

    assert_equal "RuntimeError", logged["error"]
  end

  def test_the_server_reports_a_failed_request_without_its_arguments
    with_fake_eccc do |fake|
      app = application(fake, logger: WeatherCanadaMCP::Logger.new(io: @io, format: "json"))
      response = app.mcp_server.handle(tool_call("no_such_tool", location: SECRET))

      assert response.key?(:error)
      refute_includes @io.string, SECRET
      assert_equal %w[unhandled_exception tools/call no_such_tool], logged.values_at("msg", "method", "tool")
    ensure
      app&.close
    end
  end
end
