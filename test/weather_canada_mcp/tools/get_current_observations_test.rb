# frozen_string_literal: true

require_relative "../../test_helper"

class GetCurrentObservationsTest < Minitest::Test
  WHISTLER = { lat: 50.12, lon: -122.96 }.freeze

  def observations(**) = call_with_fake("get_current_observations", **)

  def reports(id) = FakeEccc.fixture_json("api/swob-realtime_#{id}.json")["features"].map { |feature| feature["properties"] }

  def test_nearest_stations_closest_first_with_the_newest_readings
    result, error = observations(**WHISTLER)
    nesters = result["stations"].first

    refute error
    assert_equal(%w[1100875 1048899 1101300], result["stations"].map { |station| station["id"] })
    assert_equal ["WHISTLER - NESTERS", "MSC", 661.8, 1.1], nesters.values_at("name", "provider", "elevation_m", "distance_km")
    assert_equal "2026-11-15T11:41:00-07:00", nesters["observed_at"]
    temperature, humidity, pressure = reports("1100875").first.values_at("air_temp", "rel_hum", "stn_pres")

    assert_equal [temperature, humidity, (pressure / 10.0).round(3)],
                 nesters["observations"].values_at("temperature_c", "humidity_pct", "pressure_station_kpa")
  end

  # The NAV CANADA station gives 6-hour precipitation and 24-hour extremes only in its top-of-hour report.
  def test_readings_missing_from_the_newest_report_come_from_one_within_the_hour
    whistler = observations(**WHISTLER).first["stations"].find { |station| station["id"] == "1048899" }
    top_of_hour = reports("1048899").find { |report| report["date_tm-value"] == "2026-11-15T18:00:00.000Z" }

    assert_equal "2026-11-15T11:28:00-07:00", whistler["observed_at"]
    assert_equal reports("1048899").first["air_temp"], whistler.dig("observations", "temperature_c")
    assert_equal top_of_hour.values_at("pcpn_amt_pst6hrs", "max_air_temp_pst24hrs", "tot_cld_amt"),
                 whistler["observations"].values_at("precipitation_past_6h_mm", "max_temperature_past_24h_c", "cloud_cover_pct")
    assert_equal "2026-11-15T11:00:00-07:00", whistler.dig("earlier_readings", "precipitation_past_6h_mm")
    refute whistler["earlier_readings"].key?("temperature_c")
  end

  # Whistler - Nesters flags its snow depth with 0, not 100 (passed).
  def test_readings_that_failed_quality_checks_are_left_out
    nesters = observations(**WHISTLER, limit: 1).first["stations"].first

    assert_equal 0, reports("1100875").first["snw_dpth-qa"]
    refute nesters["observations"].key?("snow_depth_cm")
    assert nesters["observations"].key?("temperature_c")
  end

  def test_a_silent_station_gives_its_place_to_the_next_nearest
    empty = '{"type":"FeatureCollection","features":[]}'
    silent = lambda do |request|
      next [200, {}, empty] if request.query["msc_id-value"] == "1100875"

      [200, {}, FakeEccc.fixture("api/swob-realtime_#{request.query["msc_id-value"]}.json")]
    end
    result, = observations(**WHISTLER, limit: 2, routes: { "/collections/swob-realtime/items" => silent })

    assert_equal(%w[1048899 1101300], result["stations"].map { |station| station["id"] })
  end

  # The capture script repeats the tool's query by hand; the captured fixture records the query it was made with.
  def test_fixtures_were_captured_with_the_query_the_tool_sends
    _, _, requests = observations(**WHISTLER, limit: 1)
    sent = requests.find { |request| request.path == "/collections/swob-realtime/items" }.query
    captured = FakeEccc.fixture_json("api/swob-realtime_1100875.json")["links"].find { |link| link["rel"] == "self" }["href"]

    captured = URI.decode_www_form(URI(captured).query).to_h
    by_set = ->(query) { query.except("f").merge("properties" => query["properties"].split(",").sort) }

    assert_equal by_set.call(sent), by_set.call(captured)
  end

  def test_readings_flagged_missing_are_left_out
    whistler = observations(**WHISTLER).first["stations"].find { |station| station["id"] == "1048899" }

    assert_equal(-1, reports("1048899").first["max_wnd_gst_spd_10m_pst10mts-qa"])
    refute whistler["observations"].key?("wind_gust_kmh")
    refute whistler["observations"].key?("precipitation_past_24h_mm")
  end

  def test_wind_speed_and_direction_come_from_one_report_and_calm_has_no_direction
    stations = observations(**WHISTLER).first["stations"]
    callaghan = stations.find { |station| station["id"] == "1101300" }
    calm = stations.find { |station| station["id"] == "1048899" }

    assert_equal [4.1, 171], callaghan["observations"].values_at("wind_speed_kmh", "wind_direction_deg")
    assert_in_delta 0.0, calm.dig("observations", "wind_speed_kmh")
    refute calm["observations"].key?("wind_direction_deg")
  end

  def test_asks_for_few_reports_and_only_the_readings_it_uses
    _, _, requests = observations(**WHISTLER, limit: 1)
    swob = requests.find { |request| request.path == "/collections/swob-realtime/items" }

    assert_equal 2, requests.size
    assert_equal({ "msc_id-value" => "1100875", "sortby" => "-date_tm-value", "limit" => "6" },
                 swob.query.slice("msc_id-value", "sortby", "limit"))
    assert_includes swob.query["properties"].split(","), "air_temp-qa"
  end

  def test_old_reports_are_flagged
    result, = observations(**WHISTLER, limit: 1, clock: -> { STATIONS_CAPTURED_AT + (4 * 3600) })

    assert_match(/more than 3 hours old/, result["stations"].first["note"])
  end

  def test_a_station_whose_reports_fail_is_listed_with_a_note
    result, error = observations(**WHISTLER, routes: { "/collections/swob-realtime/items" => ->(_) { [404, {}, "gone"] } })

    refute error
    assert_equal 3, result["stations"].size
    assert_match(/could not be fetched/, result["stations"].first["note"])
    refute result["stations"].first.key?("observations")
  end

  def test_no_station_nearby
    empty = '{"type":"FeatureCollection","features":[]}'
    result, = observations(**WHISTLER, routes: { "/collections/swob-stations/items" => ->(_) { [200, {}, empty] } })

    assert_empty result["stations"]
    assert_match(/No Environment Canada or NAV CANADA weather station/, result["note"])
  end

  def test_by_place_name
    result, = observations(location: "Whistler", limit: 1)

    assert_equal "Whistler", result.dig("location", "query_match", "name")
    assert_equal 1, result["stations"].size
  end
end
