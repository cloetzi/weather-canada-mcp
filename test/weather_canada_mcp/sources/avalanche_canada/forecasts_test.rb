# frozen_string_literal: true

require_relative "../../../test_helper"

class AvalancheCanadaForecastsTest < Minitest::Test
  def source = WeatherCanadaMCP::Sources::AvalancheCanada::Forecasts.new(http: nil, cache: nil)

  def test_rejects_arguments_that_would_reach_a_path_or_query_unchecked
    assert_raises(ArgumentError) { source.product_at(51.42, -116.18, "../en") }
    assert_raises(ArgumentError) { source.product_at(Float::NAN, -116.18, "en") }
  end

  def test_unexpected_shapes_are_invalid_responses
    with_fake_eccc do |fake|
      fake.route("/forecasts/en/metadata") { [200, { "content-type" => "application/json" }, '{"not":"a list"}'] }
      app = application(fake, **AVALANCHE_ENABLED)

      assert_raises(WeatherCanadaMCP::Sources::InvalidResponse) { app.avalanche.forecasts.metadata("en") }
    ensure
      app&.close
    end
  end
end
