# frozen_string_literal: true

require_relative "../../test_helper"

class GetAlertsTest < Minitest::Test
  def alerts(clock: -> { CAPTURED_AT }, **arguments)
    result = nil
    with_fake_eccc do |fake|
      app = application(fake, clock:)
      result = call_tool(app, "get_alerts", **arguments).first
    ensure
      app&.close
    end
    result
  end

  def test_alerts_covering_the_point_with_verbatim_text
    result = alerts(lat: 53.54, lon: -113.49)
    alert = result["alerts"].first
    original = FakeEccc.fixture_json("api/weather-alerts_edmonton.json")["features"].first["properties"]

    assert_equal 1, result["alerts"].size
    assert_equal ["fog advisory", "advisory", "FGA"], alert.values_at("headline", "type", "code")
    assert_equal original["alert_text_en"], alert["text"]
    assert_equal "2026-11-15T23:01:28.613Z", alert["expires_at"]
  end

  def test_french_text
    alert = alerts(lat: 53.54, lon: -113.49, lang: "fr")["alerts"].first
    original = FakeEccc.fixture_json("api/weather-alerts_edmonton.json")["features"].first["properties"]

    assert_equal original["alert_text_fr"], alert["text"]
    assert_equal "avis de brouillard", alert["headline"]
  end

  def test_by_place_name
    result = alerts(location: "Squamish")

    assert_equal "Squamish", result.dig("location", "query_match", "name")
    assert_equal "rainfall warning", result["alerts"].first["headline"]
  end

  def test_expired_alerts_are_dropped
    result = alerts(lat: 53.54, lon: -113.49, clock: -> { Time.utc(2026, 11, 16) })

    assert_empty result["alerts"]
    assert_empty result["nearby_alerts"]
  end

  def test_no_alerts
    result = alerts(lat: 45.42, lon: -75.7)

    assert_empty result["alerts"]
    assert_match %r{weather\.gc\.ca/warnings}, result["source_url"]
  end

  # The upstream bbox query also returns alerts whose area only comes close to the point.
  def test_alerts_near_but_not_covering_the_point_are_listed_briefly
    result = nil
    with_fake_eccc do |fake|
      fake.route("/collections/weather-alerts/items") { [200, {}, FakeEccc.fixture("api/weather-alerts_edmonton.json")] }
      app = application(fake)
      result, = call_tool(app, "get_alerts", lat: 51.05, lon: -114.06)
    ensure
      app&.close
    end

    assert_empty result["alerts"]
    assert_match(/City of Edmonton/, result["nearby_alerts"].first["area"])
    refute result["nearby_alerts"].first.key?("text")
  end
end
