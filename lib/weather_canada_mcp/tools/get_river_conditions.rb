# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Real-time water level and flow at the nearest hydrometric gauges, with the recent trend and how the flow compares
    # with the historical mean for the month (HYDAT monthly means).
    class GetRiverConditions < Base
      REALTIME_COLLECTION = "hydrometric-realtime"
      MONTHLY_COLLECTION = "hydrometric-monthly-mean"
      RADIUS_KM = 50
      SAME_RIVER_KM = 1
      MAX_STATIONS = 5
      TREND_HOURS = 72
      # A flow change under this share of the flow counts as steady.
      STEADY_SHARE = 0.05
      STALE_AFTER = 6 * 3600
      PRELIMINARY = "Real-time readings are preliminary and unverified: they can change after review, and ice or equipment " \
                    "problems can affect them."
      tool_name "get_river_conditions"
      title "Get river levels and flows"
      description <<~TEXT
        Real-time water level (m) and flow (m3/s) at the Water Survey of Canada gauges nearest a location (within 50 km),
        with the change over 24 hours, the range over 3 days, and today's flow against the historical mean for this month.
        river keeps only gauges whose name contains it; when location names a river ("Ottawa River", "Rivière des
        Outaouais"), only gauges on that river within 50 km of the spot the name resolves to are used (a long river is
        resolved to one point, so give a town on it for another stretch). Data are provisional and can be affected by ice; compare a level
        only with the same gauge. This is not a flood forecast: use get_alerts for warnings.
      TEXT
      location_arguments
      argument :river, :string, max_length: 60, description: "Only gauges whose name contains this text (\"Bow River\")."
      argument :limit, :integer, in: 1..MAX_STATIONS, default: 3, description: "Nearest gauges to include."
      argument :lang, :language

      output :gauges, :array, "The nearest gauges, closest first."

      def call(args)
        lang = args.lang
        point = args.point
        limit = args.limit
        # An explicit river replaces the river the location names.
        filter, source = (argument = river_filter(args.river)) ? [argument, :argument] : [river_place_filter(point), :place]
        stations = gauges(point, filter, limit).then { |nearest| concurrently(nearest) { |distance, feature| gauge(feature, distance, lang) } }
        { location: point.to_h, gauges: stations, note: [note(stations, filter && source, args.river), PRELIMINARY].compact.join(" ") }
      end

      private

      def river_filter(river)
        return if river.nil?

        normalized = RiverNames.normalize(river)
        normalized.empty? ? nil : ->(name) { name.include?(normalized) }
      end

      # A river named as the location: gauges on it, wherever its name is spelled in English or French.
      def river_place_filter(point)
        return unless point.place&.type == "River"

        same_spot = @context.gazetteer.open.nearest(point.lat, point.lon, radius_km: SAME_RIVER_KM, limit: 20).map(&:last)
        RiverNames.new(point.place, same_spot).filter
      end

      def gauges(point, filter, limit)
        stations.hydrometric.nearest(point.lat, point.lon, count: limit, radius_km: RADIUS_KM) do |feature|
          filter.nil? || filter.call(RiverNames.normalize(feature.dig("properties", "STATION_NAME").to_s))
        end
      end

      # source is :argument or :place, the origin of the river filter, or nil without one.
      def note(gauges, source, river)
        return "Only gauges on the river are listed; give a town on it for another stretch." if gauges.any? && source == :place
        return unless gauges.empty?

        case source
        when :place then "No real-time gauge on this river within #{RADIUS_KM} km of the spot its name resolves to. Give a town on the river instead."
        when :argument then "No real-time gauge named like #{river.inspect} within #{RADIUS_KM} km."
        else "No real-time gauge within #{RADIUS_KM} km."
        end
      end

      def gauge(feature, distance, lang)
        info = gauge_info(feature, distance, lang)
        number = info[:id]
        # The history does not depend on the readings, so both are fetched at once.
        readings, (means, means_note) = concurrently([-> { readings(number) }, -> { monthly_means(number, now.utc.month) }], &:call)
        return info.merge(note: "No real-time readings in the past #{TREND_HOURS / 24} days.") if readings.empty?

        latest = readings.first
        info[:note] = "The latest reading is more than #{STALE_AFTER / 3600} hours old." if now - latest[:at] > STALE_AFTER
        info.merge(latest: reading_h(latest), past_24h: change(readings, 24), past_3_days: range(readings),
                   this_month_historically: historical(means, means_note, readings))
      rescue Sources::Error => e
        info.merge(note: "This gauge's readings could not be fetched: #{e.message}")
      end

      def gauge_info(feature, distance, lang)
        properties = feature["properties"]
        lon, lat = feature.dig("geometry", "coordinates")
        number = properties["STATION_NUMBER"]
        operator = properties["CONTRIBUTOR_#{lang.upcase}"].to_s
        { name: properties["STATION_NAME"], id: number, province: properties["PROV_TERR_STATE_LOC"],
          operator: (operator unless operator.empty?), drainage_area_km2: properties["DRAINAGE_AREA_GROSS"]&.round,
          distance_km: round_km(distance), lat:, lon:, url: "https://wateroffice.ec.gc.ca/report/real_time_#{lang == "fr" ? "f" : "e"}.html?stn=#{number}" }
      end

      # Newest first, as {at:, level:, discharge:}.
      def readings(number)
        return [] unless number.is_a?(String)

        since = Time.at((now - (TREND_HOURS * 3600)).to_i / 3600 * 3600).utc.iso8601
        data = ogc.items(REALTIME_COLLECTION, STATION_NUMBER: number, datetime: "#{since}/..", sortby: "-DATETIME",
                                              properties: "DATETIME,LEVEL,DISCHARGE", skipGeometry: true, limit: 3000)
        readings = Array(data["features"]).filter_map do |feature|
          properties = feature["properties"] || {}
          at = time(properties["DATETIME"])
          { at:, level: number_or_nil(properties["LEVEL"]), discharge: number_or_nil(properties["DISCHARGE"]) } if at
        end
        readings.sort_by { |reading| -reading[:at].to_f }
      end

      def number_or_nil(value) = value.is_a?(Numeric) ? value.to_f : nil

      def reading_h(reading)
        { observed_at: reading[:at], level_m: reading[:level]&.round(3), discharge_m3s: discharge(reading[:discharge]) }
      end

      def discharge(value) = value && (value < 10 ? value.round(2) : value.round(1))

      # The change since the reading closest to hours ago, and whether the flow (or the level) is rising.
      def change(readings, hours)
        latest = readings.first
        target = latest[:at] - (hours * 3600)
        earlier = readings.min_by { |reading| (reading[:at] - target).abs }
        return if earlier.equal?(latest) || (earlier[:at] - target).abs > 3 * 3600

        level = delta(latest[:level], earlier[:level])
        flow = delta(latest[:discharge], earlier[:discharge])
        { level_change_m: level&.round(3), discharge_change_m3s: discharge(flow),
          trend: trend(flow, earlier[:discharge]) || trend(level, nil) }
      end

      def delta(now_value, then_value) = now_value && then_value && (now_value - then_value)

      def trend(change, base)
        return if change.nil?

        threshold = base ? base.abs * STEADY_SHARE : 0.02 # metres, for a level-only gauge
        return "steady" if change.abs <= threshold

        change.positive? ? "rising" : "falling"
      end

      def range(readings)
        levels = readings.filter_map { |reading| reading[:level] }
        flows = readings.filter_map { |reading| reading[:discharge] }
        { min_level_m: levels.min&.round(3), max_level_m: levels.max&.round(3),
          min_discharge_m3s: discharge(flows.min), max_discharge_m3s: discharge(flows.max) }
      end

      # The mean flow over the past 24 hours against the mean, lowest and highest monthly mean for this calendar month.
      def historical(means, means_note, readings)
        return { note: "The historical means could not be fetched: #{means_note}" } if means_note
        return if means.empty?

        current = mean_of(readings.select { |reading| readings.first[:at] - reading[:at] <= 86_400 }.filter_map { |reading| reading[:discharge] })
        mean = mean_of(means.values)
        lowest, highest = means.values.minmax
        {
          month: now.utc.month, years: means.size, from_year: means.keys.min, to_year: means.keys.max, mean_discharge_m3s: discharge(mean),
          lowest_monthly_mean_m3s: discharge(lowest), highest_monthly_mean_m3s: discharge(highest),
          past_24h_mean_discharge_m3s: discharge(current), percent_of_mean: percent(current, mean)
        }
      end

      def mean_of(values) = (values.sum / values.size if values.any?)

      def percent(value, base) = ((value / base * 100).round if value && base&.positive?)

      # {year => mean discharge} for one calendar month, from HYDAT (which lags real time by a year or two). HYDAT has
      # no filter by calendar month, so the gauge's whole monthly record is fetched (cached for a week). A failure is
      # reported as a note, not raised, so the real-time readings are still reported.
      def monthly_means(number, month)
        return [{}, nil] unless number.is_a?(String)

        attempt { monthly_record(number, month) }
      end

      def monthly_record(number, month)
        data = ogc.items(MONTHLY_COLLECTION, STATION_NUMBER: number, properties: "DATE,MONTHLY_MEAN_DISCHARGE", skipGeometry: true,
                                             limit: 2000)
        Array(data["features"]).each_with_object({}) do |feature, means|
          properties = feature["properties"] || {}
          year, m = properties["DATE"].to_s.split("-").map(&:to_i)
          value = properties["MONTHLY_MEAN_DISCHARGE"]
          means[year] = value.to_f if m == month && value.is_a?(Numeric)
        end
      end
    end
  end
end
