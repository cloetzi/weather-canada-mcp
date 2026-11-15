# frozen_string_literal: true

require_relative "../../../test_helper"

class StationDirectoryTest < Minitest::Test
  Directory = WeatherCanadaMCP::Sources::ECCC::StationDirectory
  WHISTLER = [50.12, -122.96].freeze

  def with_ogc
    with_fake_eccc do |fake|
      app = application(fake)
      yield app.ogc, fake
    ensure
      app&.close
    end
  end

  def test_the_whole_list_is_read_once_and_searched_in_memory
    with_ogc do |ogc, fake|
      directory = Directory.new(ogc:, collection: "swob-stations", properties: "name,msc_id,data_provider")
      nearest = directory.nearest(*WHISTLER, count: 3, radius_km: 50)
      directory.nearest(45.4, -75.7, count: 1, radius_km: 50)

      assert_equal 3, nearest.size
      assert_equal nearest.map(&:first).sort, nearest.map(&:first)
      assert_operator nearest.first.first, :<, 2
      assert_equal "WHISTLER - NESTERS", nearest.first.last.dig("properties", "name")
      assert_equal 1, fake.requests_to("/collections/swob-stations/items").size
      query = fake.requests_to("/collections/swob-stations/items").first.query

      assert_equal "5000", query["limit"]
      assert_equal "name,msc_id,data_provider", query["properties"]
    end
  end

  def test_the_radius_count_and_filter_narrow_the_stations
    with_ogc do |ogc,|
      directory = Directory.new(ogc:, collection: "swob-stations")

      assert_empty directory.nearest(*WHISTLER, count: 5, radius_km: 0.01)
      assert_equal 2, directory.nearest(*WHISTLER, count: 2, radius_km: 50).size
      only = directory.nearest(*WHISTLER, count: 5, radius_km: 50) { |feature| feature.dig("properties", "msc_id") == "1048899" }

      assert_equal(["1048899"], only.map { |_, feature| feature.dig("properties", "msc_id") })
      assert_equal 1, directory.nearest(45.4, -75.7, count: 1).size, "without a radius the nearest anywhere is found"
    end
  end

  def test_a_collection_too_large_to_list_is_read_for_the_grid_cell_around_the_point
    with_ogc do |ogc, fake|
      directory = Directory.new(ogc:, collection: "hydrometric-stations", grid: true, REAL_TIME: 1)
      near = directory.nearest(49.70, -123.15, count: 3, radius_km: 50)
      directory.nearest(49.72, -123.20, count: 3, radius_km: 50)
      requests = fake.requests_to("/collections/hydrometric-stations/items")

      assert_equal 3, near.size
      assert_equal 1, requests.size, "points in the same 0.5 degree cell share one request"
      assert_equal "1", requests.first.query["REAL_TIME"]
      assert_equal WeatherCanadaMCP::Geo.snapped_bbox(49.70, -123.15, 50).join(","), requests.first.query["bbox"]
      directory.nearest(51.2, -116.2, count: 1, radius_km: 50)

      assert_equal 2, fake.requests_to("/collections/hydrometric-stations/items").size
    end
  end

  def test_features_without_a_point_are_skipped
    with_ogc do |ogc, fake|
      fake.route("/collections/swob-stations/items") do |_|
        body = { features: [{ geometry: nil, properties: { name: "none" } },
                            { geometry: { coordinates: [-122.96, 50.12] }, properties: { name: "here" } },
                            { geometry: { coordinates: [-122.96, 50.12] }, properties: nil }] }
        [200, {}, JSON.generate(body)]
      end

      assert_equal(["here"], Directory.new(ogc:, collection: "swob-stations").features.map { |feature| feature.dig("properties", "name") })
    end
  end

  def test_the_snapped_box_always_holds_the_circle_around_the_point
    [[50.12, -122.96], [60.1, -135.0], [41.7, -82.5], [48.99, -123.49], [53.0, -113.0]].each do |lat, lon|
      min_lon, min_lat, max_lon, max_lat = WeatherCanadaMCP::Geo.snapped_bbox(lat, lon, 50)
      around = WeatherCanadaMCP::Geo.bbox(lat, lon, 50)

      assert_operator min_lon, :<=, around[0]
      assert_operator min_lat, :<=, around[1]
      assert_operator max_lon, :>=, around[2]
      assert_operator max_lat, :>=, around[3]
    end
  end
end
