# frozen_string_literal: true

require_relative "../../test_helper"

class GetClimateContextTest < Minitest::Test
  WHISTLER = { lat: 50.12, lon: -122.96 }.freeze

  def climate(clock: -> { GEOMET_CAPTURED_AT }, **) = call_with_fake("get_climate_context", clock:, **)

  def test_daily_records_of_the_nearest_place
    result, error = climate(**WHISTLER)

    refute error
    assert_equal [11, 15], result.values_at("month", "day")
    records = result["daily_records"]

    assert_equal({ "name" => "WHISTLER AREA", "id" => "VSBC86V", "distance_km" => 0.7 }, records["station"])
    assert_equal({ "value" => 14.6, "year" => 2019 }, records.dig("temperature", "highest_max_c"))
    assert_equal({ "value" => -17.8, "year" => 1955 }, records.dig("temperature", "lowest_min_c"))
    assert_equal({ "most_mm" => { "value" => 45.8, "year" => 2021 }, "records_since" => 1931 }, records["precipitation"])
    assert_equal({ "most_cm" => { "value" => 19.3, "year" => 1950 }, "records_since" => 1931 }, records["snowfall"])
  end

  def test_monthly_normals_of_the_nearest_normals_station
    normals = climate(**WHISTLER).first["monthly_normals"]

    assert_equal({ "name" => "WHISTLER", "climate_id" => "1048898", "distance_km" => 1.1 }, normals["station"])
    assert_equal "1981-2010", normals["period"]
    assert_equal [3.45, -1.76, 192.14, 65.67, 9.65, 17.25],
                 normals.values_at("mean_daily_max_c", "mean_daily_min_c", "total_precipitation_mm", "snowfall_cm",
                                   "days_with_snowfall", "month_end_snow_depth_cm")
  end

  def test_asks_for_the_day_and_month_given
    _, _, requests = climate(**WHISTLER, date: "2027-11-15")
    queries = requests.map(&:query)

    assert_equal([%w[11 15]] * 3, queries.first(3).map { |query| query.values_at("LOCAL_MONTH", "LOCAL_DAY") })
    assert_equal({ "CLIMATE_IDENTIFIER" => "1048898", "MONTH" => "11" }, queries.last.slice("CLIMATE_IDENTIFIER", "MONTH"))
  end

  def test_today_is_the_local_day
    # 02:00 UTC on November 16 is still November 15 in British Columbia.
    _, _, requests = climate(**WHISTLER, clock: -> { Time.utc(2026, 11, 16, 2) })

    assert_equal %w[11 15], requests.first.query.values_at("LOCAL_MONTH", "LOCAL_DAY")
  end

  def test_invalid_dates
    result, error = climate(**WHISTLER, date: "2026-02-30")

    assert error
    assert_match(/date must be YYYY-MM-DD or MM-DD/, result)
    ["11/15", "2026-11-5"].each { |date| assert(climate(**WHISTLER, date:)[1], "#{date} should be refused") }
  end

  def test_normals_failure_still_gives_the_records
    result, error = climate(**WHISTLER, routes: { "/collections/climate-normals/items" => ->(_) { [503, {}, "busy"] } })

    refute error
    assert_equal "VSBC86V", result.dig("daily_records", "station", "id")
    assert_match(/climate normals could not be fetched/, result.dig("monthly_normals", "note"))
  end

  def test_nothing_nearby
    empty = ->(_) { [200, {}, '{"type":"FeatureCollection","features":[]}'] }
    routes = %w[ltce-temperature ltce-precipitation ltce-snowfall climate-normals].to_h { |c| ["/collections/#{c}/items", empty] }
    result, = climate(**WHISTLER, routes:)

    assert_match(/No climate records within 100 km/, result.dig("daily_records", "note"))
    assert_match(/No climate normals station within 50 km/, result.dig("monthly_normals", "note"))
  end

  def test_french_station_name
    assert_equal "WHISTLER", climate(**WHISTLER, lang: "fr").first.dig("daily_records", "station", "name")
  end
end
