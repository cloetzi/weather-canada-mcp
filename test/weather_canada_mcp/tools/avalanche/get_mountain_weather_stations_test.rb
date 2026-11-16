# frozen_string_literal: true

require_relative "../../../test_helper"

class AvalancheGetMountainWeatherStationsTest < Minitest::Test
  LAKE_LOUISE = { lat: 51.42, lon: -116.18 }.freeze

  def stations(**) = call_with_fake("get_mountain_weather_stations", clock: -> { AVALANCHE_CAPTURED_AT }, env: AVALANCHE_ENABLED, **)

  def measurements(id) = FakeEccc.fixture_json("avalanche/measurements_#{id}.json")

  def test_nearest_stations_with_elevation_and_distance
    result, error = stations(**LAKE_LOUISE)

    refute error
    assert_equal([["Bosworth Upper", 2745, 13], ["Bosworth Lower", 2210, 13], ["Whymper", 2600, 24]],
                 result["stations"].map { |station| station.values_at("name", "elevation_m", "distance_km") })
    assert_equal ["Parks Canada"], result["stations"].map { |station| station["source"] }.uniq
  end

  # Alberta stopped changing the clock on 1 November 2026: Lake Louise is on UTC-6 all year.
  def local(utc) = Time.iso8601(utc).getlocal("-06:00").iso8601

  def test_latest_reading
    upper = stations(**LAKE_LOUISE).first["stations"].find { |station| station["id"] == 111 }
    newest = measurements(111).first

    assert_equal local(newest["measurementDateTime"]), upper.dig("latest", "observed_at")
    assert_equal newest.values_at("airTempAvg", "windSpeedAvg", "windDirCompass", "windSpeedGust"),
                 upper["latest"].values_at("temperature_c", "wind_speed_kmh", "wind_direction", "wind_gust_kmh")
  end

  def test_window_summary
    lower = stations(**LAKE_LOUISE).first["stations"].find { |station| station["id"] == 110 }
    readings = measurements(110)
    heights = readings.filter_map { |reading| reading["snowHeight"] }

    assert_equal readings.size, lower.dig("window", "readings")
    assert_in_delta (heights.first - heights.last).round(1), lower.dig("window", "snow_depth_change_cm")
    assert_in_delta readings.sum { |reading| reading["newSnow"].to_f }, lower.dig("window", "new_snow_cm")
    assert_in_delta readings.map { |reading| reading["airTempAvg"] }.min, lower.dig("window", "min_temperature_c")
  end

  def test_max_gust
    upper = stations(**LAKE_LOUISE).first["stations"].find { |station| station["id"] == 111 }
    gust = measurements(111).max_by { |reading| reading["windSpeedGust"].to_f }

    assert_equal [gust["windSpeedGust"], gust["windDirGustCompass"], local(gust["measurementDateTime"])],
                 upper["window"].values_at("max_gust_kmh", "max_gust_direction", "max_gust_at")
  end

  # The capture script repeats the tool's window by hand: the 24 hours up to the next full hour.
  def test_asks_for_the_window_the_fixtures_were_captured_with
    _, _, requests = stations(**LAKE_LOUISE)
    query = requests.find { |request| request.path == "/stations/110/measurements" }.query
    times = measurements(110).map { |reading| Time.iso8601(reading["measurementDateTime"]) }

    assert_equal({ "fromDate" => "2026-11-14T20:00:00Z", "toDate" => "2026-11-15T20:00:00Z" }, query)
    assert(times.all? { |time| time.between?(Time.iso8601(query["fromDate"]), Time.iso8601(query["toDate"])) })
  end

  def test_silent_stations_are_skipped_for_the_next_nearest
    result, = stations(**LAKE_LOUISE, limit: 1, routes: { "/stations/111/measurements" => ->(_) { [200, {}, "[]"] } })

    assert_equal([110], result["stations"].map { |station| station["id"] })
  end

  def test_a_station_that_fails_gets_a_note
    result, error = stations(**LAKE_LOUISE, routes: { "/stations/109/measurements" => ->(_) { [500, {}, "oops"] } })

    refute error
    whymper = result["stations"].find { |station| station["id"] == 109 }

    assert_match(/could not be fetched/, whymper["note"])
  end

  def test_no_station_nearby
    result, = stations(lat: 45.42, lon: -75.7)

    assert_empty result["stations"]
    assert_match(/No Avalanche Canada weather station within 30 km/, result["note"])
    assert result["safety_note"].start_with?("Avalanche forecasts are regional")
  end

  def test_attribution_names_the_station_operators
    result, = stations(**LAKE_LOUISE)

    assert_equal "Mountain weather station data by Parks Canada, via Avalanche Canada (avalanche.ca). Unofficial tool, not " \
                 "affiliated with or endorsed by Avalanche Canada or Parks Canada.", result["attribution"]
  end
end
