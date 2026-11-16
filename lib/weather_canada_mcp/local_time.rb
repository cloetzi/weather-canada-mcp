# frozen_string_literal: true

require "date"

module WeatherCanadaMCP
  # Local calendar dates and times in Canadian time zones, without a time zone database: each zone's standard offset and whether
  # it keeps daylight time (second Sunday in March to first Sunday in November, at 02:00 local). Zones that have
  # stopped changing the clock are in PERMANENT. Unknown or missing zones use UTC-7, Canada's westernmost offset since BC stopped changing the clock, so a day
  # still counts as today while it is today anywhere in Canada.
  module LocalTime
    # IANA zone => [standard offset in hours, observes daylight time]
    ZONES = {
      "America/St_Johns" => [-3.5, true],
      "America/Halifax" => [-4, true], "America/Moncton" => [-4, true], "America/Glace_Bay" => [-4, true],
      "America/Goose_Bay" => [-4, true],
      "America/Toronto" => [-5, true], "America/Montreal" => [-5, true], "America/Iqaluit" => [-5, true],
      "America/Nipigon" => [-5, true], "America/Thunder_Bay" => [-5, true],
      "America/Winnipeg" => [-6, true], "America/Rankin_Inlet" => [-6, true], "America/Resolute" => [-6, true],
      "America/Regina" => [-6, false], "America/Swift_Current" => [-6, false],
      "America/Edmonton" => [-7, true], "America/Yellowknife" => [-7, true], "America/Cambridge_Bay" => [-7, true],
      "America/Inuvik" => [-7, true],
      "America/Whitehorse" => [-7, false], "America/Dawson" => [-7, false], "America/Dawson_Creek" => [-7, false],
      "America/Fort_Nelson" => [-7, false], "America/Creston" => [-7, false],
      "America/Vancouver" => [-8, true],
      "America/Atikokan" => [-5, false], "America/Blanc-Sablon" => [-4, false],
      "Canada/Newfoundland" => [-3.5, true], "Canada/Atlantic" => [-4, true], "Canada/Eastern" => [-5, true],
      "Canada/Central" => [-6, true], "Canada/Saskatchewan" => [-6, false], "Canada/Mountain" => [-7, true],
      "Canada/Yukon" => [-7, false], "Canada/Pacific" => [-8, true]
    }.freeze
    FALLBACK = [-7, false].freeze

    # Zones that stopped changing the clock and kept their daylight offset (tzdata 2026e). The 1 November 2026
    # switch from daylight time left the offset unchanged, so before the instant a zone follows ZONES and after it
    # the fixed offset applies. IANA zone => [UTC instant of the last scheduled switch, fixed offset in hours]
    PERMANENT = {
      "America/Vancouver" => [Time.utc(2026, 11, 1, 9), -7], "Canada/Pacific" => [Time.utc(2026, 11, 1, 9), -7],
      "America/Edmonton" => [Time.utc(2026, 11, 1, 8), -6], "America/Yellowknife" => [Time.utc(2026, 11, 1, 8), -6],
      "America/Inuvik" => [Time.utc(2026, 11, 1, 8), -6], "Canada/Mountain" => [Time.utc(2026, 11, 1, 8), -6],
      "America/Winnipeg" => [Time.utc(2026, 11, 1, 7), -5], "Canada/Central" => [Time.utc(2026, 11, 1, 7), -5]
    }.freeze

    module_function

    def known?(zone) = ZONES.key?(zone.to_s)

    # The time as ISO 8601 with the zone's UTC offset at that moment ("2026-11-15T08:00:00-08:00"). An unknown or nil zone
    # gives UTC ("...Z").
    def iso8601(time, zone)
      return time.utc.iso8601 unless known?(zone)

      time.getlocal((offset_hours(time, zone) * 3600).round).iso8601
    end

    def date(time, zone) = (time.utc + (offset_hours(time, zone) * 3600)).to_date

    def offset_hours(time, zone)
      since, fixed = PERMANENT[zone.to_s]
      return fixed if since && time.getutc >= since

      standard, daylight = ZONES.fetch(zone.to_s, FALLBACK)
      daylight && daylight_time?(time.utc + (standard * 3600)) ? standard + 1 : standard
    end

    # local_standard is the UTC time shifted by the standard offset; its wall-clock fields are local standard time.
    def daylight_time?(local_standard)
      year = local_standard.year
      starts = Time.utc(year, 3, nth_sunday(year, 3, 2), 2)
      ends = Time.utc(year, 11, nth_sunday(year, 11, 1), 1) # 02:00 daylight is 01:00 standard
      local_standard >= starts && local_standard < ends
    end

    def nth_sunday(year, month, nth)
      first = Date.new(year, month, 1)
      1 + ((7 - first.wday) % 7) + (7 * (nth - 1))
    end
  end
end
