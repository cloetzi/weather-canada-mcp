# frozen_string_literal: true

require_relative "../test_helper"

class LocalTimeTest < Minitest::Test
  LocalTime = WeatherCanadaMcp::LocalTime

  def test_dates_in_mountain_time_across_daylight_saving
    # MST (UTC-7) in winter, MDT (UTC-6) in summer.
    assert_equal Date.new(2026, 11, 15), LocalTime.date(Time.utc(2026, 11, 16, 6, 59), "America/Edmonton")
    assert_equal Date.new(2026, 11, 16), LocalTime.date(Time.utc(2026, 11, 16, 7, 0), "America/Edmonton")
    assert_equal Date.new(2026, 7, 1), LocalTime.date(Time.utc(2026, 7, 2, 5, 59), "America/Edmonton")
    assert_equal Date.new(2026, 7, 2), LocalTime.date(Time.utc(2026, 7, 2, 6, 0), "America/Edmonton")
  end

  def test_daylight_saving_boundaries
    # 2026: from Sunday 8 March 02:00 to Sunday 1 November 02:00 local.
    assert_equal(-8, LocalTime.offset_hours(Time.utc(2026, 3, 8, 9, 59), "America/Vancouver"))
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 3, 8, 10, 0), "America/Vancouver"))
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 11, 1, 8, 59), "America/Vancouver"))
    assert_equal(-8, LocalTime.offset_hours(Time.utc(2026, 11, 1, 9, 0), "America/Vancouver"))
  end

  def test_zones_without_daylight_saving_newfoundland_and_unknown_zones
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 7, 1), "America/Whitehorse"))
    assert_equal(-6, LocalTime.offset_hours(Time.utc(2026, 7, 1), "America/Regina"))
    assert_in_delta(-2.5, LocalTime.offset_hours(Time.utc(2026, 7, 1), "America/St_Johns"))
    assert_equal 0, LocalTime.offset_hours(Time.utc(2026, 7, 1), "Europe/Paris")
    assert_equal 0, LocalTime.offset_hours(Time.utc(2026, 7, 1), nil)
  end
end
