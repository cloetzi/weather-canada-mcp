# frozen_string_literal: true

require_relative "../../../test_helper"

class OgcApiTest < Minitest::Test
  def with_ogc(logger: null_logger)
    with_fake_eccc do |fake|
      app = application(fake, logger:)
      yield app.ogc, fake
    ensure
      app&.close
    end
  end

  def test_items_ask_for_json_with_the_params_and_are_cached
    with_ogc do |ogc, fake|
      2.times { ogc.items("swob-stations", limit: 5, properties: "name") }
      request = fake.requests_to("/collections/swob-stations/items").sole

      assert_equal({ "f" => "json", "limit" => "5", "properties" => "name" }, request.query)
      assert_match(/geo\+json/, request.headers["accept"])
    end
  end

  def test_an_item_by_id
    with_ogc do |ogc, fake|
      assert_equal "bc-50", ogc.item("citypageweather-realtime", "bc-50").dig("properties", "identifier")
      assert_equal 1, fake.requests_to("/collections/citypageweather-realtime/items/bc-50").size
    end
  end

  def test_arguments_that_would_reach_the_path_unchecked_are_refused
    with_ogc do |ogc,|
      assert_raises(ArgumentError) { ogc.items("../secret") }
      assert_raises(ArgumentError) { ogc.items("swob-stations/items") }
      assert_raises(ArgumentError) { ogc.item("citypageweather-realtime", "a/b") }
    end
  end

  def test_a_failing_status_names_the_host_it_went_to
    with_ogc do |ogc, fake|
      fake.route("/collections/swob-stations/items") { [404, {}, "gone"] }
      error = assert_raises(WeatherCanadaMCP::Sources::StatusError) { ogc.items("swob-stations") }

      assert_equal 404, error.status
      assert_match(/\A127\.0\.0\.1 has no data/, error.message)
    end
  end

  def test_a_response_that_is_not_json_or_not_an_object_is_invalid
    with_ogc do |ogc, fake|
      fake.route("/collections/swob-stations/items") { [200, {}, "<html>"] }
      fake.route("/collections/swob-realtime/items") { [200, {}, "[1]"] }

      assert_match(/not valid JSON/, assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) { ogc.items("swob-stations") }.message)
      assert_match(/unexpected shape/, assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) { ogc.items("swob-realtime") }.message)
    end
  end

  def test_a_list_cut_short_by_its_limit_is_logged_without_the_query
    io = StringIO.new
    with_ogc(logger: WeatherCanadaMCP::Logger.new(io:, level: "warn")) do |ogc, fake|
      fake.route("/collections/swob-stations/items") { [200, {}, '{"features":[],"numberMatched":938,"numberReturned":500}'] }
      ogc.items("swob-stations", limit: 500, bbox: "-123,50,-122,51")
    end

    assert_match(/ogc_truncated/, io.string)
    assert_match(/swob-stations/, io.string)
    refute_match(/-123,50/, io.string, "the query holds a location")
  end

  def test_a_sorted_query_asks_for_the_first_few_on_purpose
    io = StringIO.new
    with_ogc(logger: WeatherCanadaMCP::Logger.new(io:, level: "warn")) do |ogc, fake|
      fake.route("/collections/swob-realtime/items") { [200, {}, '{"features":[],"numberMatched":900,"numberReturned":6}'] }
      ogc.items("swob-realtime", sortby: "-date_tm-value", limit: 6)
    end

    refute_match(/ogc_truncated/, io.string)
  end
end
