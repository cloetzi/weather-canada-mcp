# frozen_string_literal: true

require_relative "../test_helper"

class GeoTest < Minitest::Test
  Geo = WeatherCanadaMcp::Geo

  def test_distance
    # Squamish to Whistler City Page sites
    assert_in_delta 48.6, Geo.distance_km(49.7, -123.15, 50.12, -122.96), 0.5
    assert_in_delta 0.0, Geo.distance_km(49.7, -123.15, 49.7, -123.15)
  end

  def test_bbox_widens_longitude_with_latitude
    min_lon, min_lat, max_lon, max_lat = Geo.bbox(60.0, -120.0, 10)

    assert_in_delta 0.0898, max_lat - 60.0, 0.001
    assert_in_delta 0.1797, max_lon + 120.0, 0.001
    assert_operator min_lon, :<, -120
    assert_operator min_lat, :<, 60
  end

  def test_contains_with_real_alert_polygons
    alerts = FakeEccc.fixture_json("api/weather-alerts_edmonton.json")["features"]
    edmonton = alerts.find { |feature| feature["properties"]["feature_name_en"].start_with?("City of Edmonton") }

    assert Geo.contains?(edmonton["geometry"], 53.54, -113.49)
    refute Geo.contains?(edmonton["geometry"], 51.05, -114.06) # Calgary
  end

  def test_holes_multipolygons_and_unclosed_rings
    square = [[0, 0], [10, 0], [10, 10], [0, 10]]
    hole = [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]]

    assert Geo.contains?({ "type" => "Polygon", "coordinates" => [square] }, 5, 5)
    refute Geo.contains?({ "type" => "Polygon", "coordinates" => [square, hole] }, 5, 5)
    assert Geo.contains?({ "type" => "MultiPolygon", "coordinates" => [[hole], [square.map { |x, y| [x + 20, y] }]] }, 5, 25)
    refute Geo.contains?({ "type" => "Point", "coordinates" => [5, 5] }, 5, 5)
    refute Geo.contains?(nil, 5, 5)
  end

  def test_distance_to_edge
    # A 0.2 degree square around 50N 120W; a point 0.1 degree of latitude north of its north edge.
    square = [[-120.1, 49.9], [-119.9, 49.9], [-119.9, 50.1], [-120.1, 50.1], [-120.1, 49.9]]

    assert_in_delta 11.13, Geo.distance_to_edge_km({ "type" => "Polygon", "coordinates" => [square] }, 50.2, -120.0), 0.05
    assert_in_delta 11.13, Geo.distance_to_edge_km({ "type" => "MultiPolygon", "coordinates" => [[square]] }, 50.2, -120.0), 0.05
    assert_in_delta 0.0, Geo.distance_to_edge_km({ "type" => "Polygon", "coordinates" => [square] }, 50.1, -120.0), 0.001
    assert_nil Geo.distance_to_edge_km({ "type" => "Point", "coordinates" => [-120, 50] }, 50, -120)
  end
end
