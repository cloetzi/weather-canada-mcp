# frozen_string_literal: true

require_relative "../../test_helper"

class AvalancheCanadaTest < Minitest::Test
  def source = WeatherCanadaMcp::Sources::AvalancheCanada.new(http: nil, cache: nil)

  def test_rejects_arguments_that_would_reach_a_path_or_query_unchecked
    assert_raises(ArgumentError) { source.product_at(51.42, -116.18, "../en") }
    assert_raises(ArgumentError) { source.product_at(Float::NAN, -116.18, "en") }
    assert_raises(ArgumentError) { source.measurements("110/../stations", from: Time.now, to: Time.now) }
    assert_raises(ArgumentError) { source.measurements(-1, from: Time.now, to: Time.now) }
  end

  def test_field_reports_cover_at_most_31_days
    today = Date.new(2026, 11, 15)
    bbox = [-117.0, 50.0, -116.0, 51.0]

    assert_raises(ArgumentError) { source.submissions(from: today - 31, to: today, bbox:) }
    assert_raises(ArgumentError) { source.submissions(from: today, to: today - 1, bbox:) }
    assert_raises(ArgumentError) { source.submissions(from: today, to: today, bbox: [1, 2, 3]) }
  end

  def test_unexpected_shapes_are_invalid_responses
    with_fake_eccc do |fake|
      fake.route("/forecasts/en/metadata") { [200, { "content-type" => "application/json" }, '{"not":"a list"}'] }
      app = application(fake, **AVALANCHE_ENABLED)

      assert_raises(WeatherCanadaMcp::Sources::InvalidResponse) { app.avalanche.metadata("en") }
    ensure
      app&.close
    end
  end
end
