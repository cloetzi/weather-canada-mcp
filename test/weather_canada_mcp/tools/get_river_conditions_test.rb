# frozen_string_literal: true

require_relative "../../test_helper"

class GetRiverConditionsTest < Minitest::Test
  SQUAMISH = { lat: 49.7, lon: -123.15 }.freeze

  def rivers(**) = call_with_fake("get_river_conditions", **)

  def readings(number)
    FakeEccc.fixture_json("api/hydrometric-realtime_#{number}.json")["features"].map do |feature|
      feature["properties"].merge("at" => Time.iso8601(feature["properties"]["DATETIME"]))
    end
  end

  def november_means(number)
    months = FakeEccc.fixture_json("api/hydrometric-monthly-mean_#{number}.json")["features"].map { |feature| feature["properties"] }
    months.select { |p| p["DATE"].end_with?("-11") && p["MONTHLY_MEAN_DISCHARGE"] }.map { |p| p["MONTHLY_MEAN_DISCHARGE"] }
  end

  def test_nearest_real_time_gauges_with_the_latest_reading
    result, error = rivers(**SQUAMISH)
    squamish = result["gauges"].last

    refute error
    assert_equal(%w[08GA076 08GA075 08GA022], result["gauges"].map { |gauge| gauge["id"] })
    assert_equal ["SQUAMISH RIVER NEAR BRACKENDALE", "BC", 2353, 11], squamish.values_at("name", "province", "drainage_area_km2", "distance_km")
    assert_equal({ "observed_at" => "2026-11-15T11:05:00-07:00", "level_m" => 4.66, "discharge_m3s" => 660.0 }, squamish["latest"])
    assert_equal "https://wateroffice.ec.gc.ca/report/real_time_e.html?stn=08GA022", squamish["url"]
  end

  def test_change_over_24_hours_and_the_3_day_range
    squamish = rivers(**SQUAMISH).first["gauges"].last
    all = readings("08GA022")
    day_ago = all.min_by { |reading| (reading["at"] - (all.first["at"] - 86_400)).abs }

    assert_in_delta all.first["DISCHARGE"] - day_ago["DISCHARGE"], squamish.dig("past_24h", "discharge_change_m3s"), 0.05
    assert_in_delta all.first["LEVEL"] - day_ago["LEVEL"], squamish.dig("past_24h", "level_change_m"), 0.0005
    assert_equal "rising", squamish.dig("past_24h", "trend")
    assert_equal all.map { |r| r["DISCHARGE"] }.minmax,
                 squamish["past_3_days"].values_at("min_discharge_m3s", "max_discharge_m3s")
  end

  def test_compares_the_flow_with_the_historical_mean_for_the_month
    history = rivers(**SQUAMISH).first["gauges"].last["this_month_historically"]
    means = november_means("08GA022")
    recent = readings("08GA022").then { |all| all.select { |r| all.first["at"] - r["at"] <= 86_400 }.map { |r| r["DISCHARGE"] } }

    assert_equal [11, means.size], history.values_at("month", "years")
    assert_in_delta means.sum / means.size, history["mean_discharge_m3s"], 0.05
    assert_in_delta means.min, history["lowest_monthly_mean_m3s"], 0.05
    assert_in_delta means.max, history["highest_monthly_mean_m3s"], 0.05
    assert_equal (recent.sum / recent.size / (means.sum / means.size) * 100).round, history["percent_of_mean"]
  end

  def test_asks_for_the_past_three_days_from_the_start_of_the_hour
    _, _, requests = rivers(**SQUAMISH, limit: 1)
    realtime = requests.find { |request| request.path == "/collections/hydrometric-realtime/items" }
    stations = requests.find { |request| request.path == "/collections/hydrometric-stations/items" }

    assert_equal "1", stations.query["REAL_TIME"]
    assert_equal "2026-11-12T18:00:00Z/..", realtime.query["datetime"]
    assert_equal "DATETIME,LEVEL,DISCHARGE", realtime.query["properties"]
  end

  def test_river_keeps_matching_gauges_ignoring_case_and_accents
    result, = rivers(**SQUAMISH, river: "mamquam")
    accented, = rivers(**SQUAMISH, river: "SQUÂMISH river", limit: 1)

    assert_equal(["MAMQUAM RIVER ABOVE RING CREEK"], result["gauges"].map { |gauge| gauge["name"] })
    assert_equal(["SQUAMISH RIVER NEAR BRACKENDALE"], accented["gauges"].map { |gauge| gauge["name"] })
  end

  # A river named as the location keeps the gauges on that river, in either language: the CGN lists it under both names.
  def test_a_river_as_the_location_keeps_the_gauges_on_it
    ["Ottawa River", "Rivière des Outaouais"].each do |location|
      result, error = rivers(location:, limit: 5)

      refute error, location
      names = result["gauges"].map { |gauge| gauge["name"] }

      refute_empty names, location
      assert(names.all? { |name| name.start_with?("OUTAOUAIS (RIVIERE DES)") }, "#{location}: #{names}")
      assert_match(/Only gauges on the river/, result["note"])
    end
  end

  def test_a_blank_river_argument_leaves_the_river_of_the_location
    result, = rivers(location: "Ottawa River", river: "  ")

    refute_empty result["gauges"]
    assert_match(/Only gauges on the river/, result["note"])
  end

  def test_a_river_argument_replaces_the_river_of_the_location
    result, = rivers(location: "Ottawa River", river: "no such gauge")

    assert_empty result["gauges"]
    assert_match(/named like "no such gauge"/, result["note"])
  end

  def test_a_river_with_no_gauge_near_asks_for_a_town
    result, = rivers(location: "Bow River")

    assert_empty result["gauges"]
    assert_match(/Give a town on the river/, result["note"])
  end

  def test_the_river_names_match_from_the_start_of_the_gauge_name
    filter = WeatherCanadaMCP::Tools::RiverNames.new(river("Bow River"), []).filter

    assert filter.call("BOW RIVER AT BANFF")
    refute filter.call("ELBOW RIVER AT SARCEE BRIDGE")
    refute filter.call("LITTLE BOW RIVER AT CARMANGAY")
    refute filter.call("BOW RIVERSIDE CREEK")
    assert_nil WeatherCanadaMCP::Tools::RiverNames.new(river("Banff", "Town"), []).filter
  end

  def test_french_and_punctuated_river_names
    assert WeatherCanadaMCP::Tools::RiverNames.new(river("Rivière du Loup"), []).filter.call("LOUP (RIVIERE DU) A ESPRIT-SAINT")
    assert WeatherCanadaMCP::Tools::RiverNames.new(river("Rivière Dumoine"), []).filter.call("DUMOINE (RIVIERE) A LA SORTIE DU LAC ROBINSON")
    assert WeatherCanadaMCP::Tools::RiverNames.new(river("Rivière de l'Outaouais"), []).filter.call("OUTAOUAIS (RIVIERE DE L') A X")
    assert WeatherCanadaMCP::Tools::RiverNames.new(river("St. John River"), []).filter.call("ST JOHN RIVER AT FREDERICTON")
    assert WeatherCanadaMCP::Tools::RiverNames.new(river("Rivière Saint-Jean"), []).filter.call("SAINT-JEAN (RIVIERE) A X")
  end

  def river(name, type = "River") = WeatherCanadaMCP::Places::Gazetteer::Place.new(name, type, "Water Feature", "Alberta", 50.0, -115.0, 68.0)

  def test_the_readings_are_called_preliminary
    result, = rivers(**SQUAMISH)

    assert_match(/preliminary and unverified/, result["note"])
  end

  def test_no_matching_gauge
    result, = rivers(**SQUAMISH, river: "Fraser")

    assert_empty result["gauges"]
    assert_match(/No real-time gauge named like "Fraser" within 50 km/, result["note"])
  end

  def test_a_gauge_whose_readings_fail_is_listed_with_a_note
    result, error = rivers(**SQUAMISH, limit: 1, routes: { "/collections/hydrometric-realtime/items" => ->(_) { [404, {}, "gone"] } })

    refute error
    assert_match(/could not be fetched/, result["gauges"].first["note"])
    refute result["gauges"].first.key?("latest")
  end

  def test_without_the_history_the_real_time_readings_are_still_reported
    result, = rivers(**SQUAMISH, limit: 1, routes: { "/collections/hydrometric-monthly-mean/items" => ->(_) { [404, {}, "gone"] } })
    gauge = result["gauges"].first

    assert gauge.key?("latest")
    assert_match(/historical means could not be fetched/, gauge.dig("this_month_historically", "note"))
  end

  def test_fixtures_were_captured_with_the_query_the_tool_sends
    _, _, requests = rivers(**SQUAMISH, limit: 1)
    %w[hydrometric-realtime hydrometric-monthly-mean].each do |collection|
      sent = requests.find { |request| request.path == "/collections/#{collection}/items" }.query
      captured = FakeEccc.fixture_json("api/#{collection}_08GA076.json")["links"].find { |link| link["rel"] == "self" }["href"]

      assert_equal sent.except("f"), URI.decode_www_form(URI(captured).query).to_h.except("f"), collection
    end
  end

  def test_old_readings_are_flagged
    result, = rivers(**SQUAMISH, limit: 1, clock: -> { STATIONS_CAPTURED_AT + (8 * 3600) })

    assert_match(/more than 6 hours old/, result["gauges"].first["note"])
  end
end
