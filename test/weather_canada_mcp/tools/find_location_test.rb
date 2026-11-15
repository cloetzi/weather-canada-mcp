# frozen_string_literal: true

require_relative "../../test_helper"

class FindLocationTest < Minitest::Test
  def find(**arguments)
    result = nil
    with_fake_eccc do |fake|
      app = application(fake)
      result = call_tool(app, "find_location", **arguments)
    ensure
      app&.close
    end
    result
  end

  def test_candidates_and_forecast_sites_for_a_name
    result, error = find(location: "Whistler")

    refute error
    assert_equal "Whistler", result["candidates"].first["name"]
    assert_equal "bc-86", result["forecast_sites"].first["id"]
    assert_match(/Canadian Geographical Names/, result["attribution"])
  end

  def test_province_argument_narrows_the_candidates
    result, = find(location: "Lake Louise", province: "AB", limit: 10)

    assert(result["candidates"].all? { |place| place["province"] == "Alberta" })
  end

  def test_unknown_province_is_an_error
    message, error = find(location: "Bow River", province: "Alta")

    assert error
    assert_match(/Unknown province/, message)
  end

  def test_coordinates_give_nearby_places_and_sites
    result, = find(lat: 49.7, lon: -123.15)

    assert_equal "Squamish", result["nearby_places"].first["name"]
    assert_equal "bc-50", result["forecast_sites"].first["id"]
  end

  def test_no_match_is_not_an_error
    result, error = find(location: "Nowhereville")

    refute error
    assert_empty result["candidates"]
  end

  def test_missing_query
    message, error = find

    assert error
    assert_match(/Give a location/, message)
  end
end
