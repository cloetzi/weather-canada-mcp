# frozen_string_literal: true

require_relative "../../test_helper"

class GetAirQualityTest < Minitest::Test
  KELOWNA = { lat: 49.89, lon: -119.5 }.freeze

  def air_quality(**) = call_with_fake("get_air_quality", **)

  def test_nearest_location_with_the_latest_observation
    result, error = air_quality(**KELOWNA)

    refute error
    assert_equal({ "id" => "JAFUV", "name" => "Central Okanagan", "distance_km" => 1.4, "lat" => 49.8833333333333, "lon" => -119.483333333333 },
                 result["aqhi_location"])
    assert_equal({ "observed_at" => "2026-11-15T14:00:00-07:00", "aqhi" => 1.5, "aqhi_display" => "1", "risk" => "low" }, result["current"])
  end

  def test_forecast_periods_from_the_latest_publication
    forecast = air_quality(**KELOWNA).first["forecast"]

    assert_equal "2026-11-15T06:00:00-07:00", forecast["issued_at"]
    assert_equal(["Today", "Tonight", "Tomorrow", "Tomorrow Night"], forecast["periods"].map { |period| period["period"] })
    assert_equal [2, "low"], forecast["periods"].first.values_at("aqhi", "risk")
  end

  def test_health_messages_once_per_risk_category
    messages = air_quality(**KELOWNA).first["health_messages"]

    assert_equal ["low"], messages.keys
    assert_equal "Enjoy your usual outdoor activities.", messages.dig("low", "general")
  end

  def test_french
    result, = air_quality(**KELOWNA, lang: "fr")

    assert_equal "Okanagan - centre", result.dig("aqhi_location", "name")
    assert_equal "Aujourd'hui", result.dig("forecast", "periods", 0, "period")
    assert_equal ["faible"], result["health_messages"].keys
  end

  def test_asks_for_period_forecasts_of_that_location
    _, _, requests = air_quality(**KELOWNA)
    observations, forecasts = requests.map(&:query)

    assert_equal "true", observations["latest"]
    assert_equal({ "location_id" => "JAFUV", "aqhi_type" => "AQHI-Forecast-Period", "sortby" => "-publication_datetime", "limit" => "1" },
                 forecasts.slice("location_id", "aqhi_type", "sortby", "limit"))
  end

  def test_no_location_nearby
    empty = '{"type":"FeatureCollection","features":[]}'
    result, = air_quality(**KELOWNA, routes: { "/collections/aqhi-observations-realtime/items" => ->(_) { [200, {}, empty] } })

    assert_match(/No AQHI location within 100 km/, result["note"])
  end

  def test_without_the_forecast_the_observation_is_still_reported
    result, error = air_quality(**KELOWNA, routes: { "/collections/aqhi-forecasts-realtime/items" => ->(_) { [404, {}, "gone"] } })

    refute error
    assert_equal "low", result.dig("current", "risk")
    assert_match(/forecast could not be fetched/, result.dig("forecast", "note"))
  end

  def test_risk_categories_follow_the_rounded_index
    tool = WeatherCanadaMCP::Tools::GetAirQuality.new(nil)
    risks = [1.4, 3.4, 3.5, 6.4, 6.5, 10.4, 10.5, 12].map { |value| tool.send(:index, value, "en").values_at(:risk, :aqhi_display) }

    assert_equal [%w[low 1], %w[low 3], %w[moderate 4], %w[moderate 6], %w[high 7], %w[high 10], ["very high", "10+"],
                  ["very high", "10+"]], risks
  end
end
