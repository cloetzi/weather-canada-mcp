# frozen_string_literal: true

require_relative "../../test_helper"

class GetRadarMapTest < Minitest::Test
  WHISTLER = { lat: 50.12, lon: -122.96 }.freeze
  RADAR_CAPTURED_AT = Time.utc(2026, 11, 15, 19, 33)

  def radar(**) = call_with_fake("get_radar_map", clock: -> { RADAR_CAPTURED_AT }, **)

  # The whole MCP content list (JSON text, then the image) and the fake's requests.
  def radar_content(routes: {}, **arguments)
    result = nil
    with_fake_eccc do |fake|
      routes.each { |path, handler| fake.route(path, &handler) }
      app = application(fake, clock: -> { RADAR_CAPTURED_AT })
      response = app.mcp_server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_radar_map", arguments: } })
      result = [response.dig(:result, :content), fake.tool_requests]
    ensure
      app&.close
    end
    result
  end

  def test_rates_at_the_point_now_and_over_the_past_hour
    result, error = radar(**WHISTLER)

    refute error
    assert_equal "2026-11-15T11:30:00-08:00", result["observed_at"]
    assert_equal({ "snow_cm_per_h" => 0, "rain_mm_per_h" => 0 }, result["at_point"])
    assert_equal [{ "time" => "2026-11-15T11:00:00-08:00", "snow_cm_per_h" => 0 }, { "time" => "2026-11-15T10:30:00-08:00", "snow_cm_per_h" => 0 }],
                 result["past_hour"]
  end

  def test_map_details_and_base_map_attribution
    result = radar(**WHISTLER).first
    map = result["map"]

    assert_equal ["snow", 100, 512, 512], map.values_at("precipitation", "radius_km", "width", "height")
    assert_equal WeatherCanadaMCP::Geo.bbox(50.1, -122.95, 100), map["bounds"].values_at("min_lon", "min_lat", "max_lon", "max_lat")
    assert_match(%r{\Acm/h: light blue 0.1}, map["legend"])
    assert_includes result["attribution"], WeatherCanadaMCP::Sources::NRCan::Basemap::ATTRIBUTION
    assert_includes result["attribution"], WeatherCanadaMCP::ATTRIBUTION
  end

  def test_the_image_is_a_png_with_the_point_ringed
    content, = radar_content(**WHISTLER)
    image = content.last

    assert_equal %w[image image/png], image.values_at(:type, :mimeType)
    png = image[:data].unpack1("m0")

    assert_equal [512, 512], WeatherCanadaMCP::Maps::Compositor.dimensions(png)
    canvas = ChunkyPNG::Image.from_blob(png)
    bbox = WeatherCanadaMCP::Geo.bbox(50.1, -122.95, 100)
    x = ((-122.96 - bbox[0]) / (bbox[2] - bbox[0]) * 512).floor
    y = ((bbox[3] - 50.12) / (bbox[3] - bbox[1]) * 512).floor

    assert_equal WeatherCanadaMCP::Maps::Compositor::MARKER, canvas[x + 7, y]
  end

  def test_asks_for_one_frame_of_each_layer
    _, requests = radar_content(**WHISTLER)
    geomet = requests.select { |request| request.path == "/geomet" }.map { |request| request.query.values_at("REQUEST", "LAYERS", "TIME") }

    assert_equal ["GetFeatureInfo", "RADAR_1KM_RSNO", nil], geomet.first
    assert_includes geomet, ["GetMap", "RADAR_1KM_RSNO", "2026-11-15T19:30:00Z"]
    assert_includes geomet, ["GetMap", "RADAR_COVERAGE_RRAI.INV", "2026-11-15T19:30:00Z"]
    assert_includes geomet, ["GetFeatureInfo", "RADAR_1KM_RSNO", "2026-11-15T18:30:00Z"]
    map = requests.find { |request| request.query["LAYERS"] == "RADAR_1KM_RSNO" && request.query["REQUEST"] == "GetMap" }.query

    assert_equal %w[Radar-Snow_14colors TRUE 512], map.values_at("STYLES", "TRANSPARENT", "WIDTH")
    assert_equal(1, requests.count { |request| request.path == "/wms/CBMT" })
  end

  def test_without_the_base_map_the_radar_is_drawn_on_white
    content, = radar_content(**WHISTLER, routes: { "/wms/CBMT" => ->(_) { [503, {}, "busy"] } })
    result = JSON.parse(content.first[:text])

    assert_match(/base map could not be used \(maps.geogratis.gc.ca failed/, result.dig("map", "note"))
    refute result["map"].key?("base_map")
    assert_equal "image", content.last[:type]
  end

  def test_an_unreadable_base_map_is_left_out
    content, = radar_content(**WHISTLER, routes: { "/wms/CBMT" => lambda { |_|
      [200, { "content-type" => "image/png" }, "#{WeatherCanadaMCP::Sources::PNG_SIGNATURE}junk"]
    } })
    result = JSON.parse(content.first[:text])

    assert_match(/base map could not be used \(A map image was not the 512x512/, result.dig("map", "note"))
    assert_equal "image", content.last[:type]
  end

  def test_the_composed_map_is_kept_for_the_frame
    with_fake_eccc do |fake|
      app = application(fake, clock: -> { RADAR_CAPTURED_AT })
      call = -> { app.mcp_server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_radar_map", arguments: WHISTLER } }) }
      first = call.call.dig(:result, :content).last[:data]
      keys = app.image_cache.instance_variable_get(:@entries).keys

      assert_equal(1, keys.count { |key| key.start_with?("radar-map:snow,") })
      assert_equal first, call.call.dig(:result, :content).last[:data]
      assert_equal keys, app.image_cache.instance_variable_get(:@entries).keys
    ensure
      app&.close
    end
  end

  def test_rain_scale_asks_for_the_rain_layer
    result, error, requests = radar(**WHISTLER, precipitation: "rain")

    refute error
    assert_equal "RADAR_1KM_RRAI", requests.first.query["LAYERS"]
    # No rain frame was captured as the latest one, so the fake answers like GeoMet with no data.
    assert_match(/no image for this location/, result["note"])
  end

  def test_a_map_geomet_cannot_draw_is_an_error
    xml = '<?xml version="1.0"?><ServiceExceptionReport><ServiceException/></ServiceExceptionReport>'
    latest = FakeEccc.fixture("geomet/whistler/RADAR_1KM_RSNO_latest.json")
    geomet = ->(request) { request.query["REQUEST"] == "GetMap" ? [200, { "content-type" => "text/xml" }, xml] : [200, {}, latest] }
    result, error = radar(**WHISTLER, routes: { "/geomet" => geomet })

    assert error
    assert_match(/could not draw RADAR_1KM_RSNO/, result)
  end
end
