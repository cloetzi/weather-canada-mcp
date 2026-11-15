# frozen_string_literal: true

require_relative "../../test_helper"

# One result per tool for a fixture location, kept in test/fixtures/results/. A change to any tool's output shows up as a
# diff here (UPDATE_SNAPSHOTS=1 rake test rewrites them); every key in them must be on the vocabulary list.
class ResultSnapshotsTest < Minitest::Test
  RESULTS = File.join(TestHelpers::ROOT, "test/fixtures/results")
  VOCABULARY = File.join(RESULTS, "vocabulary.txt")
  WHISTLER = { lat: 50.12, lon: -122.96 }.freeze
  SQUAMISH = { lat: 49.7, lon: -123.15 }.freeze
  LAKE_LOUISE = { lat: 51.42, lon: -116.18 }.freeze
  # Names this contract replaced; they must not come back.
  RETIRED = %w[air_temp_c relative_humidity_pct wind_kmh snow_height_cm published_at radar_time site_id station_number climate_id
               stations_count].freeze

  # tool => [arguments, clock, avalanche?]
  CASES = {
    "find_location" => [{ location: "Whistler" }, :captured],
    "get_forecast" => [{ **SQUAMISH, hours: 3 }, :captured],
    "get_alerts" => [{ lat: 53.54, lon: -113.49 }, :captured],
    "get_current_observations" => [WHISTLER, :stations],
    "get_air_quality" => [{ lat: 49.89, lon: -119.5 }, :stations],
    "get_marine_forecast" => [{ lat: 49.5, lon: -123.3 }, :stations],
    "get_river_conditions" => [SQUAMISH, :stations],
    "get_climate_context" => [WHISTLER, :geomet],
    "get_snow_outlook" => [WHISTLER, :geomet],
    "get_radar_map" => [WHISTLER, :radar],
    "get_avalanche_forecast" => [LAKE_LOUISE, :avalanche, true],
    "get_avalanche_danger_overview" => [{}, :avalanche, true],
    "get_mountain_weather_stations" => [LAKE_LOUISE, :avalanche, true],
    "get_field_reports" => [{ lat: 50.41, lon: -116.5, radius_km: 10, days: 31 }, :avalanche, true]
  }.freeze

  def clock(kind)
    time = { captured: CAPTURED_AT, stations: STATIONS_CAPTURED_AT, geomet: GEOMET_CAPTURED_AT, avalanche: AVALANCHE_CAPTURED_AT,
             radar: Time.utc(2026, 11, 15, 19, 33) }.fetch(kind)
    -> { time }
  end

  def result_for(tool, (arguments, clock_kind, avalanche))
    call_with_fake(tool, clock: clock(clock_kind), env: (avalanche ? AVALANCHE_ENABLED : {}), **arguments)
  end

  def snapshots
    CASES.to_h do |tool, setup|
      result, error = result_for(tool, setup)

      refute error, "#{tool}: #{result}"
      [tool, result]
    end
  end

  def keys_in(value)
    case value
    when Hash then value.flat_map { |key, item| [key, *keys_in(item)] }
    when Array then value.flat_map { |item| keys_in(item) }
    else []
    end
  end

  def test_every_tool_has_a_snapshot
    assert_equal WeatherCanadaMCP::Tools::Registry::ALL.map(&:tool_name).sort, CASES.keys.sort
  end

  def test_results_match_their_snapshots
    snapshots.each do |tool, result|
      path = File.join(RESULTS, "#{tool}.json")
      json = "#{JSON.pretty_generate(result)}\n"
      File.write(path, json) if ENV["UPDATE_SNAPSHOTS"]

      assert_equal File.read(path, encoding: Encoding::UTF_8), json, "#{tool}'s result changed; review and run UPDATE_SNAPSHOTS=1 rake test"
    end
  end

  def test_result_keys_are_in_the_vocabulary
    vocabulary = File.readlines(VOCABULARY, chomp: true)
    used = snapshots.values.flat_map { |result| keys_in(result) }.uniq.sort

    assert_empty used - vocabulary, "keys missing from #{VOCABULARY}: add them only if the CONTRIBUTING.md vocabulary has no name for them"
    assert_empty vocabulary & RETIRED
  end
end
