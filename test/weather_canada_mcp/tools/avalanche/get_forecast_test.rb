# frozen_string_literal: true

require_relative "../../../test_helper"

class AvalancheGetForecastTest < Minitest::Test
  LAKE_LOUISE = { lat: 51.42, lon: -116.18 }.freeze
  TORONTO = { lat: 43.65, lon: -79.38 }.freeze
  SAFETY_NOTE = "Avalanche forecasts are regional and do not replace avalanche training, your own observations or terrain " \
                "judgement. Check the official forecast before you go: "

  def forecast(clock: -> { AVALANCHE_CAPTURED_AT }, **) = call_with_fake("get_avalanche_forecast", clock:, env: AVALANCHE_ENABLED, **)

  def fixture(lang = "en") = FakeEccc.fixture_json("avalanche/point_#{lang}_lake-louise.json")

  def test_ratings_from_today_in_the_forecast_time_zone
    ratings = forecast(**LAKE_LOUISE).first.dig("forecast", "danger_ratings")

    # Issued on Saturday the 14th for three days; at capture time it is Sunday in Alberta.
    assert_equal([%w[2026-11-15 Sunday], %w[2026-11-16 Monday]], ratings.map { |day| day.values_at("date", "day") })
  end

  def test_ratings_keep_avalanche_canadas_own_values
    day = forecast(**LAKE_LOUISE).first.dig("forecast", "danger_ratings", 0)

    assert_equal({ "rating" => "earlyseason", "display" => "Early Season" }, day["alpine"])
    assert_equal({ "rating" => "earlyseason", "display" => "Early Season" }, day["treeline"])
    assert_equal({ "rating" => "norating", "display" => "No Rating" }, day["below_treeline"])
  end

  def test_days_limits_the_ratings
    ratings = forecast(**LAKE_LOUISE, days: 1).first.dig("forecast", "danger_ratings")

    assert_equal(["Sunday"], ratings.map { |day| day["day"] })
  end

  def test_problems
    problem = forecast(**LAKE_LOUISE).first.dig("forecast", "problems", 0)

    assert_equal({ "type" => "Wind Slab", "type_id" => "windslab", "elevations" => ["Alpine"], "aspects" => %w[N NE E SE S SW W NW],
                   "likelihood" => "unlikely", "likelihood_id" => "unlikely", "expected_size" => { "min" => 1.0, "max" => 1.5 },
                   "comment" => "Isolated small wind slabs are possible in steep alpine lee terrain." }, problem)
  end

  def test_text_is_verbatim_with_only_the_html_removed
    result = forecast(**LAKE_LOUISE).first["forecast"]
    report = fixture["report"]
    summary = report["summaries"].find { |s| s.dig("type", "value") == "snowpack-summary" }["content"]

    assert_equal summary.strip.delete_prefix("<p>").delete_suffix("</p>"), result["snowpack_summary"]
    assert_equal WeatherCanadaMCP::HtmlText.plain(report["highlights"]), result["highlights"]
    assert_equal report["terrainAndTravelAdvice"], result["terrain_and_travel_advice"]
    assert_equal report.dig("confidence", "statements"), result.dig("confidence", "statements")
    refute_match(/<[a-z]/i, JSON.generate(result))
  end

  def test_links_and_text_of_the_weather_summary_survive_as_text
    summary = forecast(**LAKE_LOUISE).first.dig("forecast", "weather_summary")

    assert_includes summary, "see the telemetry stations on the Avalanche Canada map page."
    refute_includes summary, "&nbsp;"
  end

  def test_links_in_the_text_are_listed_separately
    links = forecast(**LAKE_LOUISE).first.dig("forecast", "links")
    notification = fixture.dig("notifications", 0, "content")
    url = notification[/href="([^"]+)"/, 1]

    assert_includes links, { "text" => "here", "url" => url }
    assert_includes links.map { |link| link["url"] }, "https://www.avalanche.ca/map"
  end

  # Variants of the captured product, served in place of it, for shapes the capture does not show.
  def with_product(&change)
    product = fixture
    change.call(product)
    { "/forecasts/en/products/point" => ->(_) { [200, {}, JSON.generate(product)] } }
  end

  def test_only_avalanche_ca_links_are_passed_on_as_official
    result, = forecast(**LAKE_LOUISE, routes: with_product { |product| product["url"] = "javascript:alert(1)" })

    assert_nil result.dig("forecast", "url")
    assert result["safety_note"].end_with?("https://avalanche.ca/map")
  end

  def test_unexpected_shapes_are_skipped_not_fatal
    result, error = forecast(**LAKE_LOUISE, routes: with_product do |product|
      product["report"]["dangerRatings"][1]["ratings"] = []
      product["report"]["dangerRatings"][2]["date"] = "Monday"
      product["report"]["problems"] << "not a problem"
    end)

    refute error
    assert_equal(["Sunday"], result.dig("forecast", "danger_ratings").map { |day| day["day"] })
    assert_equal 1, result.dig("forecast", "problems").size
  end

  def test_owner_url_attribution_and_safety_note
    result, = forecast(**LAKE_LOUISE)

    assert_equal "Parks Canada", result.dig("forecast", "owner")
    assert_equal fixture["url"], result.dig("forecast", "url")
    assert_equal "#{SAFETY_NOTE}#{fixture["url"]}", result["safety_note"]
    assert_equal "Avalanche forecast by Parks Canada, via Avalanche Canada (avalanche.ca). Unofficial tool, not affiliated with " \
                 "or endorsed by Avalanche Canada or Parks Canada.", result["attribution"]
    refute_includes result["attribution"], "Environment and Climate Change Canada"
  end

  def test_no_logos_or_rating_graphics
    json = JSON.generate(forecast(**LAKE_LOUISE).first)

    refute_includes json, "assets.avalanche.ca"
    refute_match(/\.(png|svg|jpe?g)\b/i, json)
  end

  def test_a_point_without_coverage_never_reads_as_low
    result, error = forecast(**TORONTO)

    refute error
    assert_match(/no avalanche forecast covers this point/i, result["note"])
    assert_nil result["forecast"]
    refute_match(/\blow\b/i, JSON.generate(result.except("safety_note")))
    assert result["safety_note"].start_with?(SAFETY_NOTE)
  end

  def test_french
    result, = forecast(**LAKE_LOUISE, lang: "fr")

    assert_equal "Parcs Canada", result.dig("forecast", "owner")
    assert_equal "Conditions de début de saison", result.dig("forecast", "danger_ratings", 0, "alpine", "display")
    assert result["safety_note"].start_with?("Les prévisions d'avalanche sont régionales")
  end

  def test_the_point_is_rounded_to_a_hundredth_of_a_degree
    _, _, requests = forecast(lat: 51.4213, lon: -116.1789)

    assert_equal({ "lat" => "51.42", "long" => "-116.18" }, requests.first.query)
    assert_equal "/forecasts/en/products/point", requests.first.path
  end

  def test_nearby_points_share_a_cached_product
    with_fake_eccc do |fake|
      app = application(fake, clock: -> { AVALANCHE_CAPTURED_AT }, **AVALANCHE_ENABLED)
      call_tool(app, "get_avalanche_forecast", lat: 51.421, lon: -116.181)
      call_tool(app, "get_avalanche_forecast", lat: 51.419, lon: -116.179)

      assert_equal 1, fake.requests_to("/forecasts/en/products/point").size
    ensure
      app&.close
    end
  end

  def test_an_out_of_date_forecast_says_so
    result, = forecast(**LAKE_LOUISE, clock: -> { Time.utc(2026, 11, 20, 12) })

    assert_empty result.dig("forecast", "danger_ratings").to_a
    assert_match(/out of date/, result.dig("forecast", "note"))
  end

  def test_upstream_failures_carry_the_attribution_and_safety_note
    message, error = forecast(**LAKE_LOUISE, routes: { "/forecasts/en/products/point" => ->(_) { [503, {}, "down"] } })

    assert error
    assert_includes message, "127.0.0.1 failed to answer (HTTP 503)"
    assert_includes message, SAFETY_NOTE
    refute_includes message, "Environment and Climate Change Canada"
  end

  def test_days_must_be_one_to_three
    message, error = forecast(**LAKE_LOUISE, days: 4)

    assert error
    assert_match(%r{/days}, message)
  end
end
