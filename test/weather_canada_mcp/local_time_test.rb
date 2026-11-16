# frozen_string_literal: true

require_relative "../test_helper"

class LocalTimeTest < Minitest::Test
  LocalTime = WeatherCanadaMCP::LocalTime

  def test_mountain_time_with_daylight_saving_before_the_2026_change
    # MST (UTC-7) in winter, MDT (UTC-6) in summer, until 1 November 2026.
    assert_equal Date.new(2026, 1, 14), LocalTime.date(Time.utc(2026, 1, 15, 6, 59), "America/Edmonton")
    assert_equal Date.new(2026, 1, 15), LocalTime.date(Time.utc(2026, 1, 15, 7, 0), "America/Edmonton")
    assert_equal Date.new(2026, 7, 1), LocalTime.date(Time.utc(2026, 7, 2, 5, 59), "America/Edmonton")
    assert_equal Date.new(2026, 7, 2), LocalTime.date(Time.utc(2026, 7, 2, 6, 0), "America/Edmonton")
  end

  def test_daylight_saving_boundaries_in_the_last_season_for_the_pacific_zone
    # 2026: from Sunday 8 March 02:00 to Sunday 1 November 02:00 local, the last change.
    assert_equal(-8, LocalTime.offset_hours(Time.utc(2026, 3, 8, 9, 59), "America/Vancouver"))
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 3, 8, 10, 0), "America/Vancouver"))
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 11, 1, 8, 59), "America/Vancouver"))
  end

  # tzdata 2026e: BC, Alberta, the western Northwest Territories and Manitoba stopped changing the clock on
  # 1 November 2026 and kept their daylight offset.
  def test_zones_that_stopped_changing_the_clock_keep_the_daylight_offset
    {
      "America/Vancouver" => [-7, Time.utc(2026, 11, 1, 9)], "Canada/Pacific" => [-7, Time.utc(2026, 11, 1, 9)],
      "America/Edmonton" => [-6, Time.utc(2026, 11, 1, 8)], "America/Yellowknife" => [-6, Time.utc(2026, 11, 1, 8)],
      "America/Inuvik" => [-6, Time.utc(2026, 11, 1, 8)], "Canada/Mountain" => [-6, Time.utc(2026, 11, 1, 8)],
      "America/Winnipeg" => [-5, Time.utc(2026, 11, 1, 7)], "Canada/Central" => [-5, Time.utc(2026, 11, 1, 7)]
    }.each do |zone, (offset, switch)|
      assert_equal offset, LocalTime.offset_hours(switch - 1, zone), "#{zone} before the switch"
      assert_equal offset, LocalTime.offset_hours(switch, zone), "#{zone} after the switch"
      assert_equal offset, LocalTime.offset_hours(Time.utc(2027, 1, 15, 12), zone), "#{zone} in winter 2027"
      assert_equal offset, LocalTime.offset_hours(Time.utc(2027, 7, 15, 12), zone), "#{zone} in summer 2027"
    end
  end

  def test_the_clock_no_longer_falls_back_in_the_pacific_zone
    assert_equal "2026-11-16T16:30:00-07:00", LocalTime.iso8601(Time.utc(2026, 11, 16, 23, 30), "America/Vancouver")
    assert_equal "2026-01-15T15:30:00-08:00", LocalTime.iso8601(Time.utc(2026, 1, 15, 23, 30), "America/Vancouver")
    assert_equal Date.new(2026, 11, 15), LocalTime.date(Time.utc(2026, 11, 16, 6, 59), "America/Vancouver")
    assert_equal Date.new(2026, 11, 16), LocalTime.date(Time.utc(2026, 11, 16, 7, 0), "America/Vancouver")
  end

  def test_winter_standard_offsets_before_the_switch
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 1, 15), "America/Edmonton"))
    assert_equal(-6, LocalTime.offset_hours(Time.utc(2026, 1, 15), "America/Winnipeg"))
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 1, 15), "America/Inuvik"))
  end

  def test_zones_that_still_change_the_clock_are_unaffected
    assert_equal(-4, LocalTime.offset_hours(Time.utc(2026, 11, 1, 5, 59), "America/Toronto"))
    assert_equal(-5, LocalTime.offset_hours(Time.utc(2026, 11, 1, 6, 0), "America/Toronto"))
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2027, 1, 15), "America/Cambridge_Bay"))
    assert_equal(-6, LocalTime.offset_hours(Time.utc(2027, 7, 15), "America/Cambridge_Bay"))
    assert_equal(-5, LocalTime.offset_hours(Time.utc(2027, 1, 15), "America/Toronto"))
    assert_equal(-4, LocalTime.offset_hours(Time.utc(2027, 7, 15), "America/Toronto"))
    assert_equal(-6, LocalTime.offset_hours(Time.utc(2027, 1, 15), "America/Rankin_Inlet"))
  end

  def test_zones_without_daylight_saving_newfoundland_and_aliases
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 7, 1), "America/Whitehorse"))
    assert_equal(-6, LocalTime.offset_hours(Time.utc(2026, 7, 1), "America/Regina"))
    assert_in_delta(-2.5, LocalTime.offset_hours(Time.utc(2026, 7, 1), "America/St_Johns"))
    assert_equal(-5, LocalTime.offset_hours(Time.utc(2026, 7, 1), "America/Atikokan"))
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 7, 1), "Canada/Pacific"))
    assert_equal(-8, LocalTime.offset_hours(Time.utc(2026, 1, 15), "Canada/Pacific"))
  end

  # Westernmost, so a day is not over while it is still that day somewhere in Canada.
  def test_unknown_zones_use_the_westernmost_offset
    assert_equal(-7, LocalTime.offset_hours(Time.utc(2026, 7, 1), "Europe/Paris"))
    assert_equal Date.new(2026, 11, 15), LocalTime.date(Time.utc(2026, 11, 16, 1), nil)
  end
end
