# frozen_string_literal: true

require_relative "../../test_helper"

class GetForecastTest < Minitest::Test
  def forecast(**arguments)
    result = nil
    with_fake_eccc do |fake|
      app = application(fake)
      @fake = fake
      result = call_tool(app, "get_forecast", **arguments)
    ensure
      app&.close
    end
    result
  end

  def test_forecast_for_a_place_name
    result, error = forecast(location: "Squamish", hours: 3)

    refute error
    assert_equal "Squamish", result.dig("location", "query_match", "name")
    assert_equal "bc-50", result.dig("forecast_site", "id")
    assert_in_delta 0.5, result.dig("forecast_site", "distance_km"), 0.2
    assert_equal "Today", result["forecast"].first["name"]
    assert_match(/Rain at times heavy/, result["forecast"].first["text"])
    assert_equal({ "type" => "rain", "amount_mm" => 15 }, result["forecast"].first["precipitation"])
    assert_match(/\AData Source: Environment and Climate Change Canada/, result["attribution"])
  end

  def test_current_conditions_and_warnings
    result, = forecast(lat: 49.7, lon: -123.15, hours: 3)
    current = result["current_conditions"]

    assert_equal({ "lat" => 49.7, "lon" => -123.15, "timezone" => "America/Vancouver" }, result["location"])
    assert_equal "Squamish Airport", current["station"]
    assert_in_delta 11.3, current["temperature_c"]
    refute current.key?("wind_chill"), "a wind chill at +11 °C is stale data"
    assert_equal "YELLOW WARNING - RAINFALL", result["warnings"].first["headline"]
    assert_equal %w[sunrise sunset], result["sun"].keys
    assert_equal 3, result["hourly"].size
    refute_includes result.to_s, "nil", "nulls are removed"
  end

  def test_french
    result, = forecast(lat: 53.54, lon: -113.49, lang: "fr", hours: 0)

    assert_equal "ab-50", result.dig("forecast_site", "id")
    assert_equal "Aujourd'hui", result["forecast"].first["name"]
    assert_equal "AVIS JAUNE - BROUILLARD", result["warnings"].first["headline"]
    refute result.key?("hourly")
  end

  def test_argument_errors_are_tool_errors
    assert_equal [true, true, true, true], [
      forecast.last,
      forecast(location: "Nowhereville").last,
      forecast(lat: 40.7, lon: -74.0).last,
      forecast(lat: 49.7).last
    ]
    message, = forecast(lat: 40.7, lon: -74.0)

    assert_match(/lat/, message)
  end

  def test_upstream_failures_are_readable_tool_errors
    with_fake_eccc do |fake|
      fake.route("/collections/citypageweather-realtime/items/bc-50") { [500, {}, "boom"] }
      app = application(fake)
      message, error = call_tool(app, "get_forecast", lat: 49.7, lon: -123.15)

      assert error
      assert_match(/127\.0\.0\.1 failed to answer \(HTTP 500\)/, message)
      refute_includes message, "boom"
    ensure
      app&.close
    end
  end

  def test_concurrent_calls_keep_their_own_language
    with_fake_eccc do |fake|
      app = application(fake)
      alone = %w[en fr].map { |lang| call_tool(app, "get_forecast", lat: 49.7, lon: -123.15, lang:).first }
      together = %w[en fr].map { |lang| Async { call_tool(app, "get_forecast", lat: 49.7, lon: -123.15, lang:).first } }.map(&:wait)

      refute_equal alone.first["forecast"], alone.last["forecast"]
      assert_equal alone, together
    ensure
      app&.close
    end
  end
end
