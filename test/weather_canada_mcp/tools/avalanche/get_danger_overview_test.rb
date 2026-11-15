# frozen_string_literal: true

require_relative "../../../test_helper"

class AvalancheGetDangerOverviewTest < Minitest::Test
  def overview(**) = call_with_fake("get_avalanche_danger_overview", clock: -> { AVALANCHE_CAPTURED_AT }, env: AVALANCHE_ENABLED, **)

  def metadata(lang = "en") = FakeEccc.fixture_json("avalanche/metadata_#{lang}.json")

  def test_every_product_with_its_owner_and_ratings
    products = overview.first["products"]
    banff = products.find { |product| product["owner"] == "Parks Canada" && product["name"].start_with?("Banff") }

    assert_equal metadata.size, products.size
    assert_equal({ "rating" => "earlyseason", "display" => "Early Season" }, banff["highest_danger"])
    assert_equal({ "alpine" => "earlyseason", "treeline" => "earlyseason", "below_treeline" => "norating" }, banff["current_ratings"])
    assert banff["url"].start_with?("https://avalanche.ca/en/forecasts/")
    assert_in_delta(-116.0, banff.dig("centroid", "lon"), 1.0)
  end

  def test_noforecast_stays_as_it_is
    chic_chocs = overview.first["products"].find { |product| product["name"] == "Chic-Chocs" }

    assert_equal "noforecast", chic_chocs.dig("highest_danger", "rating")
    assert_equal "Avalanche Québec", chic_chocs["owner"]
  end

  def test_current_ratings_follow_the_icon_in_effect
    early = overview(clock: -> { Time.utc(2026, 11, 6, 0) })
    later = overview(clock: -> { Time.utc(2026, 11, 8, 0) })

    chic_chocs = ->(result) { result.first["products"].find { |product| product["name"] == "Chic-Chocs" }["current_ratings"] }

    assert_equal "noforecast", chic_chocs.call(early)["alpine"]
    assert_equal "norating", chic_chocs.call(later)["alpine"]
  end

  def test_attribution_names_every_owner_and_carries_the_safety_note
    result, = overview

    assert_match(/\AAvalanche forecasts by .*Parks Canada.*Avalanche Québec.*, via Avalanche Canada \(avalanche\.ca\)\./, result["attribution"])
    assert result["safety_note"].end_with?("Check the official forecast before you go: https://avalanche.ca/map")
  end

  def test_no_rating_graphics
    refute_includes JSON.generate(overview.first), "assets.avalanche.ca"
  end

  def test_french
    result, = overview(lang: "fr")

    assert_includes result["products"].map { |product| product["owner"] }, "Parcs Canada"
    assert result["safety_note"].end_with?("https://avalanche.ca/fr/map")
  end
end
