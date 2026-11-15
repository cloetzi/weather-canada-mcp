# frozen_string_literal: true

require_relative "../../test_helper"

class RunnerTest < Minitest::Test
  class Echo < WeatherCanadaMCP::Tools::Base
    tool_name "echo"
    title "Echo"
    description "Echoes."
    argument :size, :integer, in: 1..10_000, default: 1, description: "Size."
    argument :crash, :string, max_length: 20, description: "Crash."
    argument :secret, :string, max_length: 20, description: "Secret."

    def call(args)
      raise ArgumentError, "secret #{args.secret}" if args.crash

      { kept: "x", empty: "", none: nil, list: [nil, {}, 1], blob: "y" * args.size }
    end
  end

  class Slow < WeatherCanadaMCP::Tools::Base
    tool_name "slow"
    title "Slow"
    description "Takes a while."

    def call(_args)
      sleep 0.2
      { done: true }
    end
  end

  def runner(io: StringIO.new, max_response_bytes: 1000, **)
    WeatherCanadaMCP::Tools::Runner.new(context: nil, logger: WeatherCanadaMCP::Logger.new(io:), max_response_bytes:, **)
  end

  def text(response) = response.content.first[:text]

  def test_drops_nulls_and_empty_values_and_adds_the_attribution
    data = JSON.parse(text(runner.call(Echo, {})))

    assert_equal({ "kept" => "x", "list" => [1], "blob" => "y", "attribution" => WeatherCanadaMCP::ATTRIBUTION }, data)
  end

  def test_oversized_results_are_replaced_not_truncated
    response = runner.call(Echo, { size: 5000 })

    assert_predicate response, :error?
    assert_match(/over this server's 1000-byte limit/, text(response))
    refute_includes text(response), "yyyy"
  end

  def test_unexpected_errors_are_logged_without_their_message
    io = StringIO.new
    response = runner(io:).call(Echo, { crash: "yes", secret: "home-address" })

    assert_predicate response, :error?
    assert_match(/bug in the MCP server/, text(response))
    refute_includes io.string, "home-address"
    refute_includes text(response), "home-address"
  end

  def test_a_call_that_runs_out_of_time_is_stopped_with_an_error_that_says_so
    response = Sync { runner(deadline: 0.05).call(Slow, {}) }

    assert_predicate response, :error?
    assert_match(/took longer than 0.05 seconds/, text(response))
  end

  def test_a_call_within_its_deadline_is_untouched
    response = Sync { runner(deadline: 5).call(Slow, {}) }

    refute_predicate response, :error?
  end

  def test_calls_beyond_the_cap_are_refused_until_one_finishes
    runner = runner(max_calls: 2, deadline: 5)
    responses = Sync do |task|
      calls = Array.new(3) { task.async { runner.call(Slow, {}) } }
      calls.map(&:wait)
    end

    assert_equal [false, false, true], responses.map(&:error?)
    assert_match(/already running 2 tool calls/, text(responses.last))
    refute_predicate Sync { runner.call(Slow, {}) }, :error?, "the slots were released"
  end
end
