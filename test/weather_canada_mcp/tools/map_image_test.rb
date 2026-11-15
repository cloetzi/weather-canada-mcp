# frozen_string_literal: true

require_relative "../../test_helper"

class MapImageTest < Minitest::Test
  MapImage = WeatherCanadaMcp::Tools::MapImage
  BASE = FakeEccc.fixture_binary("nrcan/cbmt_whistler.png")
  RADAR = FakeEccc.fixture_binary("geomet/whistler/RADAR_1KM_RSNO_20261115T1930Z.png")

  def test_dimensions_from_the_header
    assert_equal [512, 512], MapImage.dimensions(BASE)
    assert_nil MapImage.dimensions('<?xml version="1.0"?>')
    assert_nil MapImage.dimensions(BASE.byteslice(0, 20))
  end

  def test_overlays_keep_the_base_where_transparent
    png = MapImage.compose([BASE, RADAR], width: 512, height: 512, marker: [10, 10])
    composed = ChunkyPNG::Image.from_blob(png)
    base = ChunkyPNG::Image.from_blob(BASE)
    radar = ChunkyPNG::Image.from_blob(RADAR)
    clear = (0...512).find { |x| ChunkyPNG::Color.a(radar[x, 500]).zero? && x > 30 }
    echo = (0...512).find { |x| ChunkyPNG::Color.a(radar[x, 500]) == 255 }

    assert_equal base[clear, 500], composed[clear, 500]
    assert_equal radar[echo, 500], composed[echo, 500]
    assert_equal MapImage::MARKER, composed[17, 10]
  end

  def test_an_image_of_another_size_is_refused_before_decoding
    error = assert_raises(WeatherCanadaMcp::Sources::InvalidResponse) { MapImage.compose([BASE], width: 256, height: 256, marker: [0, 0]) }

    assert_match(/not the 256x256 pixels/, error.message)
  end

  def test_a_broken_png_is_an_invalid_response
    broken = BASE.byteslice(0, 200)

    assert_raises(WeatherCanadaMcp::Sources::InvalidResponse) { MapImage.compose([broken], width: 512, height: 512, marker: [0, 0]) }
  end
end
