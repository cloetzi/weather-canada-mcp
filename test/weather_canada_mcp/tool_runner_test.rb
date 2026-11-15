# frozen_string_literal: true

require_relative "../test_helper"

class ToolRunnerTest < Minitest::Test
  class Echo < WeatherCanadaMcp::Tools::Base
    NAME = "echo"
    TITLE = "Echo"
    DESCRIPTION = "Echoes."
    INPUT_SCHEMA = { type: "object", properties: {} }.freeze

    def call(arguments)
      raise ArgumentError, "secret #{arguments["secret"]}" if arguments["crash"]

      { kept: "x", empty: "", none: nil, list: [nil, {}, 1], blob: "y" * arguments.fetch("size", 1) }
    end
  end

  def runner(io: StringIO.new, max_response_bytes: 1000)
    WeatherCanadaMcp::ToolRunner.new(context: nil, logger: WeatherCanadaMcp::Logger.new(io:), max_response_bytes:)
  end

  def text(response) = response.content.first[:text]

  def test_drops_nulls_and_empty_values_and_adds_the_attribution
    data = JSON.parse(text(runner.call(Echo.new(nil), {})))

    assert_equal({ "kept" => "x", "list" => [1], "blob" => "y", "attribution" => WeatherCanadaMcp::ATTRIBUTION }, data)
  end

  def test_oversized_results_are_replaced_not_truncated
    response = runner.call(Echo.new(nil), { size: 5000 })

    assert_predicate response, :error?
    assert_match(/over this server's 1000-byte limit/, text(response))
    refute_includes text(response), "yyyy"
  end

  def test_unexpected_errors_are_logged_without_their_message
    io = StringIO.new
    response = runner(io:).call(Echo.new(nil), { crash: true, secret: "home-address" })

    assert_predicate response, :error?
    assert_match(/bug in the MCP server/, text(response))
    refute_includes io.string, "home-address"
    refute_includes text(response), "home-address"
  end
end
