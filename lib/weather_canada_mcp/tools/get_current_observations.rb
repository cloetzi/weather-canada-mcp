# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # The latest surface observations (SWOB) from the ECCC and NAV CANADA stations nearest a point.
    class GetCurrentObservations < Base
      NAME = "get_current_observations"
      TITLE = "Get current weather observations"
      DESCRIPTION = <<~TEXT.tr("\n", " ").strip
        The latest measured weather at the Environment Canada and NAV CANADA stations nearest a location (within
        50 km): temperature, dewpoint, humidity, wind and gusts, pressure, visibility, cloud cover, precipitation over
        the past 1, 6 and 24 hours, snowfall and snow depth. Stations report different sets of readings, so a reading
        missing at one station may be present at the next; readings that failed ECCC's automatic quality checks are left
        out. A reading missing from a station's newest report can come from one up to an hour older; earlier_readings
        gives the time of each such reading. Each station shows its elevation and distance, because a valley station can
        differ a lot from a ridge nearby. Times are UTC (ISO 8601). For the forecast use get_forecast.
      TEXT
      STATIONS_COLLECTION = "swob-stations"
      COLLECTION = "swob-realtime"
      RADIUS_KM = 50
      MAX_STATIONS = 5
      # Reports fetched per station; a value missing from the newest report is taken from an older one within the hour.
      REPORTS = 6
      MERGE_WINDOW = 3600
      SPARE_STATIONS = 3
      STALE_AFTER = 3 * 3600
      QUALITY_PASSED = 100
      # Output field => SWOB elements, preferred first.
      FIELDS = {
        temperature_c: %w[air_temp],
        dewpoint_c: %w[dwpt_temp],
        humidity_pct: %w[rel_hum],
        wind_gust_kmh: %w[max_wnd_gst_spd_10m_pst10mts],
        max_wind_past_hour_kmh: %w[max_wnd_spd_10m_pst1hr],
        pressure_sea_level_hpa: %w[mslp],
        pressure_station_hpa: %w[stn_pres],
        visibility_km: %w[vis],
        cloud_cover_pct: %w[tot_cld_amt],
        precipitation_past_hour_mm: %w[pcpn_amt_pst1hr],
        precipitation_past_6h_mm: %w[pcpn_amt_pst6hrs],
        precipitation_past_24h_mm: %w[pcpn_amt_pst24hrs],
        snowfall_past_hour_cm: %w[snwfl_amt_pst1hr],
        snow_depth_cm: %w[snw_dpth avg_snw_dpth_pst5mts],
        max_temperature_past_24h_c: %w[max_air_temp_pst24hrs],
        min_temperature_past_24h_c: %w[min_air_temp_pst24hrs]
      }.freeze
      # Mean wind speed and direction, taken together from one report: 2-minute means, else 10-minute means.
      WIND = [%w[avg_wnd_spd_10m_pst2mts avg_wnd_dir_10m_pst2mts], %w[avg_wnd_spd_10m_pst10mts avg_wnd_dir_10m_pst10mts]].freeze
      ELEMENTS = (WIND.flatten + FIELDS.values.flatten).freeze
      PROPERTIES = ["date_tm-value", *ELEMENTS, *ELEMENTS.map { |element| "#{element}-qa" }].join(",").freeze
      INPUT_SCHEMA = {
        type: "object",
        properties: {
          **Base::LOCATION_PROPERTIES,
          stations: { type: "integer", minimum: 1, maximum: MAX_STATIONS, default: 3, description: "Nearest stations to include." },
          **Base::LANG_PROPERTY
        },
        additionalProperties: false
      }.freeze

      def call(arguments)
        lang = lang(arguments)
        point = resolve_point(arguments)
        limit = integer_argument(arguments, "stations", 3, 1..MAX_STATIONS)
        stations = reporting_stations(point, limit, lang)
        result = { location: point.to_h, stations: }
        if stations.empty?
          result[:note] =
            "No Environment Canada or NAV CANADA weather station within #{RADIUS_KM} km has reported recently; try get_forecast."
        end
        result
      end

      private

      # The nearest stations that have reported, skipping silent ones (closed or seasonal) for the next nearest.
      def reporting_stations(point, limit, lang)
        candidates = nearest_features(STATIONS_COLLECTION, point, radius_km: RADIUS_KM, count: limit + SPARE_STATIONS, limit: 500)
        first_found(candidates, limit) { |distance, feature| station(feature, distance, lang) }
      end

      # nil for a station without reports.
      def station(feature, distance, lang)
        info = station_info(feature, distance, lang)
        reports = reports(info[:id])
        newest = reports.first
        return unless newest

        info[:observed_at] = newest[:at].utc.iso8601
        info[:note] = "The latest report is more than #{STALE_AFTER / 3600} hours old." if now - newest[:at] > STALE_AFTER
        info.merge(observations(reports.select { |report| newest[:at] - report[:at] <= MERGE_WINDOW }))
      rescue Sources::Error => e
        info.merge(note: "This station's reports could not be fetched: #{e.message}")
      end

      def station_info(feature, distance, lang)
        properties = feature["properties"]
        { name: properties["name_#{lang}"] || properties["name"], id: properties["msc_id"],
          provider: properties["data_provider_#{lang}"] || properties["data_provider"],
          elevation_m: feature.dig("geometry", "coordinates", 2), distance_km: round_km(distance) }
      end

      # Newest first, as {at: Time, values: {element => value}}.
      def reports(msc_id)
        return [] unless msc_id.is_a?(String)

        data = ogc.items(COLLECTION, "msc_id-value": msc_id, sortby: "-date_tm-value", limit: REPORTS, properties: PROPERTIES)
        reports = Array(data["features"]).filter_map do |feature|
          properties = feature["properties"]
          at = time(properties&.dig("date_tm-value"))
          { at:, values: properties } if at
        end
        reports.sort_by { |report| -report[:at].to_f }
      end

      # {observations:, earlier_readings:}: each value with the time of the report it came from when that is not the
      # newest report.
      def observations(reports)
        found = FIELDS.to_h { |field, elements| [field, first_reading(reports, elements)] }.compact
        first = %i[temperature_c dewpoint_c humidity_pct]
        found = { **found.slice(*first), **wind(reports), **found.except(*first) }
        newest = reports.first[:at]
        earlier = found.filter_map { |field, (_, at)| [field, at.utc.iso8601] if at != newest }.to_h
        { observations: found.transform_values(&:first), earlier_readings: (earlier unless earlier.empty?) }
      end

      # [value, report time] from the newest report that has one of the elements.
      def first_reading(reports, elements)
        reports.each do |report|
          elements.each do |element|
            value = reading(report[:values], element)
            return [value, report[:at]] unless value.nil?
          end
        end
        nil
      end

      # Direction is left out in calm air, where stations report 0.
      def wind(reports)
        reports.each do |report|
          WIND.each do |speed_element, direction_element|
            speed = reading(report[:values], speed_element)
            next if speed.nil?

            wind = { wind_speed_kmh: [speed, report[:at]] }
            direction = reading(report[:values], direction_element) unless speed.zero?
            return direction.nil? ? wind : wind.merge(wind_direction_deg: [direction, report[:at]])
          end
        end
        {}
      end

      # Only readings that passed ECCC's automatic quality checks (flag 100); other flags mark missing, doubtful,
      # suspect or erroneous values. A reading without a flag is kept.
      def reading(values, element)
        value = values[element]
        quality = values["#{element}-qa"]
        value if value.is_a?(Numeric) && (quality.nil? || quality == QUALITY_PASSED)
      end
    end
  end
end
