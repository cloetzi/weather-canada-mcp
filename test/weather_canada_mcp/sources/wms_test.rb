# frozen_string_literal: true

require_relative "../../test_helper"

class WmsTest < Minitest::Test
  WHISTLER = [50.12, -122.96].freeze
  TIME = Time.utc(2026, 11, 15, 19, 30)

  def with_wms
    with_fake_eccc do |fake|
      app = application(fake)
      yield app.wms, fake
    ensure
      app&.close
    end
  end

  def test_a_point_value_with_its_class_and_times
    with_wms do |wms, fake|
      value = wms.feature_info("RADAR_1KM_RSNO", *WHISTLER)
      request = fake.requests_to("/geomet").sole.query

      assert_equal 0, value.value
      assert_equal %w[GetFeatureInfo RADAR_1KM_RSNO 3 3], request.values_at("REQUEST", "LAYERS", "WIDTH", "HEIGHT")
      assert_equal "application/json", request["INFO_FORMAT"]
    end
  end

  def test_nearby_points_share_one_request_and_one_cache_entry
    with_wms do |wms, fake|
      wms.feature_info("RADAR_1KM_RSNO", 50.121, -122.961)
      wms.feature_info("RADAR_1KM_RSNO", 50.124, -122.958)

      assert_equal 1, fake.requests_to("/geomet").size
      bbox = fake.requests_to("/geomet").first.query["BBOX"].split(",").map(&:to_f)

      assert_in_delta 50.12, (bbox[0] + bbox[2]) / 2, 0.0001
      assert_in_delta(-122.96, (bbox[1] + bbox[3]) / 2, 0.0001)
    end
  end

  def test_a_time_is_sent_in_utc
    with_wms do |wms, fake|
      assert_equal 0, wms.feature_info("RADAR_1KM_RSNO", *WHISTLER, time: Time.utc(2026, 11, 15, 19, 0)).value
      assert_equal "2026-11-15T19:00:00Z", fake.requests_to("/geomet").sole.query["TIME"]
    end
  end

  def test_a_time_the_layer_does_not_hold_is_an_invalid_response
    with_wms do |wms,|
      assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) { wms.feature_info("RADAR_1KM_RSNO", *WHISTLER, time: Time.utc(2020, 1, 1)) }
    end
  end

  def test_a_map_is_a_transparent_png_with_the_style_and_time
    with_wms do |wms, fake|
      png = wms.get_map("RADAR_1KM_RSNO", WeatherCanadaMCP::Geo.bbox(*WHISTLER, 100), width: 512, height: 512,
                                                                                      style: "Radar-Snow_14colors", time: TIME)
      query = fake.requests_to("/geomet").sole.query

      assert png.start_with?(WeatherCanadaMCP::Sources::PNG_SIGNATURE)
      assert_equal ["GetMap", "Radar-Snow_14colors", "TRUE", "2026-11-15T19:30:00Z", "image/png"],
                   query.values_at("REQUEST", "STYLES", "TRANSPARENT", "TIME", "FORMAT")
      assert_equal 4, query["BBOX"].split(",").size
    end
  end

  def test_a_map_the_service_cannot_draw_names_the_host
    with_wms do |wms,|
      error = assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) do
        wms.get_map("NOT_THERE", WeatherCanadaMCP::Geo.bbox(*WHISTLER, 100), width: 512, height: 512)
      end

      assert_equal "127.0.0.1 could not draw NOT_THERE for that area and time.", error.message
    end
  end

  def test_a_service_error_on_a_point_value_is_invalid_not_a_crash
    with_wms do |wms, fake|
      fake.route("/geomet") { [200, { "content-type" => "text/xml" }, FakeEccc::WMS_EXCEPTION] }

      assert_match(/could not give a value for RADAR_1KM_RSNO/, assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) do
        wms.feature_info("RADAR_1KM_RSNO", *WHISTLER)
      end.message)
    end
  end

  def test_layers_that_would_reach_the_query_unchecked_are_refused
    with_wms do |wms,|
      assert_raises(ArgumentError) { wms.feature_info("A&B=1", *WHISTLER) }
      assert_raises(ArgumentError) { wms.get_map("OK", [0, 0, 1, 1], width: 1, height: 1, style: "a b") }
    end
  end

  def test_the_base_map_is_an_opaque_image_from_its_own_service
    with_fake_eccc do |fake|
      app = application(fake)
      png = app.basemap.get_map(WeatherCanadaMCP::Geo.bbox(*WHISTLER, 100), width: 512, height: 512)
      query = fake.requests_to("/wms/CBMT").sole.query

      assert png.start_with?(WeatherCanadaMCP::Sources::PNG_SIGNATURE)
      assert_equal "CBMT", query["LAYERS"]
      refute query.key?("TRANSPARENT")
    ensure
      app&.close
    end
  end
end
