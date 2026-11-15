# frozen_string_literal: true

require_relative "../../../test_helper"

class AvalancheCanadaFieldReportsTest < Minitest::Test
  def source = WeatherCanadaMCP::Sources::AvalancheCanada::FieldReports.new(http: nil, cache: nil)

  def test_field_reports_cover_at_most_31_days
    today = Date.new(2026, 11, 15)
    bbox = [-117.0, 50.0, -116.0, 51.0]

    assert_raises(ArgumentError) { source.submissions(from: today - 31, to: today, bbox:) }
    assert_raises(ArgumentError) { source.submissions(from: today, to: today - 1, bbox:) }
    assert_raises(ArgumentError) { source.submissions(from: today, to: today, bbox: [1, 2, 3]) }
  end
end
