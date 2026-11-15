# frozen_string_literal: true

require_relative "../../test_helper"

class GetMarineForecastTest < Minitest::Test
  # The one element of a list that must have exactly one.
  module Sole
    refine Array do
      def sole = size == 1 ? first : raise(Minitest::Assertion, "expected one element, got #{size}")
    end
  end
  using Sole

  SQUAMISH = { lat: 49.7, lon: -123.15 }.freeze
  HOWE_SOUND = { lat: 49.5, lon: -123.3 }.freeze
  EASTERN_SHORE = { lat: 44.55, lon: -63.3 }.freeze
  HALIFAX = { "/collections/marineweather-realtime/items" => ->(_) { [200, {}, FakeEccc.fixture("api/marineweather-realtime_halifax.json")] } }.freeze

  def marine(**) = call_with_fake("get_marine_forecast", **)

  def test_the_area_containing_the_point
    result, error = marine(**HOWE_SOUND)

    refute error
    area = result["marine_areas"].sole

    assert_equal ["Howe Sound", "Pacific Coast", "Georgia Basin"], area.values_at("name", "region", "sub_region")
    refute area.key?("distance_km")
    assert_equal "2026-11-15T17:30:00Z", area["issued_at"]
    forecast = area["forecast"].sole

    assert_equal "Today Tonight and Monday.", forecast["period"]
    assert_match(/\AWind southerly inflow 10 to 20 knots/, forecast["wind"])
    assert_equal "Periods of rain. Risk of thunderstorms today and early this evening.", forecast["weather_visibility"]
  end

  def test_extended_forecast_with_spaces_closed_up
    extended = marine(**HOWE_SOUND).first.dig("marine_areas", 0, "extended_forecast")

    assert_equal "2026-11-15T11:00:00Z", extended["issued_at"]
    assert_equal(%w[Tuesday Wednesday Thursday], extended["periods"].map { |period| period["period"] })
    assert_equal "Wind northerly outflow 15 knots increasing to northerly outflow 25 in the afternoon.", extended.dig("periods", 0, "forecast")
  end

  def test_a_point_on_land_gets_the_nearest_area_with_its_distance
    area = marine(**SQUAMISH).first["marine_areas"].sole

    assert_equal "Howe Sound", area["name"]
    assert_in_delta 1.8, area["distance_km"], 0.5
  end

  def test_split_areas_share_the_whole_area_wave_forecast_and_warnings_in_effect
    area = marine(**EASTERN_SHORE, routes: HALIFAX).first["marine_areas"].sole

    assert_equal "Eastern Shore", area["name"]
    assert_equal(["Eastern Shore - eastern half", "Eastern Shore - western half"], area["forecast"].map { |part| part["part"] })
    assert_equal ["Seas 1 to 2 metres subsiding to 1 or less Monday evening."], area["forecast"].map { |part| part["waves"] }.uniq
    assert_equal([["Strong wind warning", "IN EFFECT"]] * 2, area["warnings"].map { |warning| warning.values_at("name", "status") })
  end

  def test_air_temperature_when_given
    area = marine(lat: 44.65, lon: -63.57, routes: HALIFAX).first["marine_areas"].sole

    assert_equal "Halifax Harbour and Approaches", area["name"]
    assert_equal "Temperatures near plus 5.", area.dig("forecast", 0, "air_temperature")
    assert_empty area["warnings"]
  end

  def test_ended_warnings_are_left_out
    data = FakeEccc.fixture_json("api/marineweather-realtime_squamish.json")
    data["features"].first["properties"]["warnings"] = {
      "locations" => [{ "events" => [{ "name" => { "en" => "Gale warning" }, "status" => { "en" => "ENDED" } }] }]
    }
    area = marine(**HOWE_SOUND, routes: { "/collections/marineweather-realtime/items" => ->(_) { [200, {}, JSON.generate(data)] } })
           .first["marine_areas"].sole

    assert_empty area["warnings"]
  end

  def test_french
    area = marine(**HOWE_SOUND, lang: "fr").first["marine_areas"].sole

    assert_equal ["baie Howe", "Côte Pacifique"], area.values_at("name", "region")
    assert_equal "aujourd'hui cette nuit et lundi.", area.dig("forecast", 0, "period")
  end

  def test_asks_for_the_areas_around_the_point
    _, _, requests = marine(**SQUAMISH)
    query = requests.sole.query

    assert_equal WeatherCanadaMCP::Geo.bbox(49.7, -123.15, 25).join(","), query["bbox"]
  end

  def test_no_area_nearby
    empty = '{"type":"FeatureCollection","features":[]}'
    result, = marine(**SQUAMISH, routes: { "/collections/marineweather-realtime/items" => ->(_) { [200, {}, empty] } })

    assert_empty result["marine_areas"]
    assert_match(/No marine forecast area within 25 km/, result["note"])
  end
end
