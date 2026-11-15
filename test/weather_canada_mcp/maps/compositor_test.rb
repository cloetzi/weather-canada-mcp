# frozen_string_literal: true

require_relative "../../test_helper"

class CompositorTest < Minitest::Test
  Compositor = WeatherCanadaMCP::Maps::Compositor
  BASE = FakeEccc.fixture_binary("nrcan/cbmt_whistler.png")
  RADAR = FakeEccc.fixture_binary("geomet/whistler/RADAR_1KM_RSNO_20261115T1930Z.png")

  def test_dimensions_from_the_header
    assert_equal [512, 512], Compositor.dimensions(BASE)
    assert_nil Compositor.dimensions('<?xml version="1.0"?>')
    assert_nil Compositor.dimensions(BASE.byteslice(0, 20))
  end

  def test_overlays_keep_the_base_where_transparent
    result = Compositor.compose([RADAR], width: 512, height: 512, marker: [10, 10], base: BASE)
    composed = ChunkyPNG::Image.from_blob(result.png)
    base = ChunkyPNG::Image.from_blob(BASE)
    radar = ChunkyPNG::Image.from_blob(RADAR)
    clear = (0...512).find { |x| ChunkyPNG::Color.a(radar[x, 500]).zero? && x > 30 }
    echo = (0...512).find { |x| ChunkyPNG::Color.a(radar[x, 500]) == 255 }

    assert_equal base[clear, 500], composed[clear, 500]
    assert_equal radar[echo, 500], composed[echo, 500]
    assert_equal Compositor::MARKER, composed[17, 10]
    assert_nil result.base_error
  end

  def test_an_unreadable_base_is_replaced_by_white
    result = Compositor.compose([RADAR], width: 512, height: 512, marker: [10, 10], base: "not a png")

    assert_match(/not the 512x512 pixels/, result.base_error)
    assert_equal ChunkyPNG::Color::WHITE, ChunkyPNG::Image.from_blob(result.png)[0, 0]
  end

  # A real 512x512 header followed by pixel data that inflates far past what 512x512 pixels can hold.
  def test_pixel_data_that_inflates_too_far_is_refused_before_decoding
    header = BASE.byteslice(0, 33)
    data = Zlib::Deflate.deflate("\0" * (8 * 1024 * 1024))
    idat = [data.bytesize].pack("N") + "IDAT".b + data + [Zlib.crc32("IDAT#{data}")].pack("N")
    bomb = header + idat + [0].pack("N") + "IEND".b + [Zlib.crc32("IEND")].pack("N")

    refute Compositor.inflates_within?(bomb, 512, 512)
    error = assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) { Compositor.compose([bomb], width: 512, height: 512, marker: [0, 0]) }
    assert_match(/more data than its size allows/, error.message)
    assert Compositor.inflates_within?(BASE, 512, 512)
  end

  def test_an_image_of_another_size_is_refused_before_decoding
    error = assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) { Compositor.compose([BASE], width: 256, height: 256, marker: [0, 0]) }

    assert_match(/not the 256x256 pixels/, error.message)
  end

  def test_a_broken_png_is_an_invalid_response
    broken = BASE.byteslice(0, 200)

    assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) { Compositor.compose([broken], width: 512, height: 512, marker: [0, 0]) }
  end
end
