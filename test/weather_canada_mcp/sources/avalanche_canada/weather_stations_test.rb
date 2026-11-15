# frozen_string_literal: true

require_relative "../../../test_helper"

class AvalancheCanadaWeatherStationsTest < Minitest::Test
  def source = WeatherCanadaMCP::Sources::AvalancheCanada::WeatherStations.new(http: nil, cache: nil)

  def test_rejects_station_ids_that_would_reach_a_path_unchecked
    assert_raises(ArgumentError) { source.measurements("110/../stations", from: Time.now, to: Time.now) }
    assert_raises(ArgumentError) { source.measurements(-1, from: Time.now, to: Time.now) }
  end
end
