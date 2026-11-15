# frozen_string_literal: true

require_relative "../../test_helper"

class GetSnowOutlookTest < Minitest::Test
  WHISTLER = { lat: 50.12, lon: -122.96 }.freeze
  WHITEHORSE = { lat: 60.72, lon: -135.05 }.freeze

  def outlook(**) = call_with_fake("get_snow_outlook", clock: -> { GEOMET_CAPTURED_AT }, **)

  def captured(place, layer, time)
    FakeEccc.fixture_json("geomet/#{place}/#{layer}_#{time}.json")["features"].first["properties"]["value"]
  end

  def test_new_snow_is_also_estimated_in_cm_at_the_stated_ratio
    result, = outlook(**WHISTLER)
    steps = result["steps"]

    assert_equal 10, result["snow_to_liquid_ratio"]
    steps.each { |step| assert_in_delta step["new_snow_water_mm"], step["new_snow_cm_estimate"], 0.001 }
    assert_in_delta steps.sum { |step| step["new_snow_cm_estimate"] }, result["total_new_snow_cm_estimate"], 0.15
  end

  def test_four_six_hour_steps_from_the_step_that_contains_now
    result, error = outlook(**WHISTLER)

    refute error
    assert_equal 6, result["step_hours"]
    starts = result["steps"].map { |step| step["valid_from"] }

    assert_equal %w[2026-11-15T10:00:00-08:00 2026-11-15T16:00:00-08:00 2026-11-15T22:00:00-08:00 2026-11-16T04:00:00-08:00], starts
    assert_equal "2026-11-16T10:00:00-08:00", result["steps"].last["valid_until"]
    assert_equal ["2026-11-15T04:00:00-08:00"], result["model_runs"]
  end

  def test_snow_level_new_snow_and_blowing_snow_at_the_end_of_each_step
    first = outlook(**WHISTLER).first["steps"].first
    level = captured("whistler", "HRDPS-WEonG_2.5km_SnowLevelHeight", "20261116T0000Z")
    snow = captured("whistler", "RDPS_10km_Snow-Accum6h", "20261116T0000Z")

    assert_equal (level / 10.0).round * 10, first["snow_level_m"]
    assert_in_delta snow, first["new_snow_water_mm"], 0.05
    assert_equal 0, first["blowing_snow_probability_pct"]
  end

  def test_total_new_snow_is_the_sum_of_the_steps
    result = outlook(**WHISTLER).first

    assert_in_delta result["steps"].sum { |step| step["new_snow_water_mm"] }, result["total_new_snow_water_mm"], 0.001
  end

  def test_snow_level_codes_are_described_not_given_as_heights
    steps = outlook(**WHITEHORSE).first["steps"]

    assert_equal(-2, captured("whitehorse", "HRDPS-WEonG_2.5km_SnowLevelHeight", "20261116T0000Z"))
    assert_match(/snow to the surface/, steps.first["snow_level"])
    assert_match(/close to the surface/, steps.last["snow_level"])
    assert(steps.none? { |step| step.key?("snow_level_m") })
  end

  def test_french_snow_level_codes
    steps = outlook(**WHITEHORSE, lang: "fr").first["steps"]

    assert_match(/neige jusqu'à la surface/, steps.first["snow_level"])
  end

  def test_asks_one_time_per_request
    _, _, requests = outlook(**WHISTLER)
    wms = requests.select { |request| request.path == "/geomet" }

    assert_equal 12, wms.size
    assert_equal %w[HRDPS-WEonG_2.5km_BlowingSnow-Prob HRDPS-WEonG_2.5km_SnowLevelHeight RDPS_10km_Snow-Accum6h],
                 wms.map { |request| request.query["LAYERS"] }.uniq.sort
    assert(wms.all? { |request| request.query["TIME"].match?(/\A2026-11-1[56]T\d\d:00:00Z\z/) })
  end

  def test_steps_the_models_cannot_answer_are_noted
    result, error = outlook(**WHISTLER, hours: 48)

    refute error
    assert_equal 12, result["step_hours"]
    # The fixtures hold 00Z and 12Z snow levels for the first day only, and no 12-hour accumulations.
    assert_match(/no values for 2 of the steps/, result["note"])
    assert(result["steps"].none? { |step| step.key?("new_snow_water_mm") })
  end

  def test_hours_given_as_a_whole_float_counts_as_the_integer
    result, error = outlook(**WHISTLER, hours: 48.0)

    refute error
    assert_equal 12, result["step_hours"]
  end

  def test_an_unknown_snow_level_code_gives_no_level
    data = FakeEccc.fixture_json("geomet/whitehorse/HRDPS-WEonG_2.5km_SnowLevelHeight_20261116T0000Z.json")
    data["features"].first["properties"]["value"] = -3
    real = FakeEccc.new
    geomet = lambda do |request|
      if request.query["LAYERS"] == "HRDPS-WEonG_2.5km_SnowLevelHeight" && request.query["TIME"] == "2026-11-16T00:00:00Z"
        return [200, { "content-type" => "application/json" }, JSON.generate(data)]
      end

      real.send(:wms_response, request.query)
    end
    result, error, requests = outlook(**WHITEHORSE, routes: { "/geomet" => geomet })

    refute error
    first = result["steps"].find { |step| step["valid_until"] == "2026-11-15T17:00:00-07:00" }

    refute first.key?("snow_level")
    refute first.key?("snow_level_m")
    refute(requests.any? { |request| request.query["LAYERS"].start_with?("RDPS-WEonG") && request.query["TIME"] == "2026-11-16T00:00:00Z" })
  end

  # The suite runs at 10 requests a second; this is the rate a real server has, with the provider's burst of 12.
  def test_a_cold_outlook_is_fast_at_the_default_rate
    elapsed = nil
    with_fake_eccc do |fake|
      app = application(fake, clock: -> { GEOMET_CAPTURED_AT }, WEATHER_MCP_REQUESTS_PER_SECOND: "1.0")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result, error = call_tool(app, "get_snow_outlook", **WHISTLER)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      refute error, result
      assert_equal 4, result["steps"].size
    ensure
      app&.close
    end

    assert_operator elapsed, :<, 3.0
  end
end
