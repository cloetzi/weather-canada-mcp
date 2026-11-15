# frozen_string_literal: true

module WeatherCanadaMcp
  module Tools
    # Real-time water level and flow at the nearest hydrometric gauges, with the recent trend and how the flow compares
    # with the historical mean for the month (HYDAT monthly means).
    class GetRiverConditions < Base
      NAME = "get_river_conditions"
      TITLE = "Get river levels and flows"
      DESCRIPTION = <<~TEXT.tr("\n", " ").strip
        Real-time water level (m) and flow (m3/s) at the Water Survey of Canada gauges nearest a location (within
        50 km), with the change over the past 24 hours, the range over the past 3 days, and how today's flow compares
        with the historical mean flow for this month at the same gauge. Pass river to keep only gauges whose name
        contains it ("Bow River", "Cheakamus"). Real-time data are provisional and can be affected by ice. Water
        levels are relative to a local datum, so compare a level only with the same gauge. Times are UTC (ISO 8601).
        This is not a flood forecast; check provincial river forecast centres and get_alerts for warnings.
      TEXT
      STATIONS_COLLECTION = "hydrometric-stations"
      REALTIME_COLLECTION = "hydrometric-realtime"
      MONTHLY_COLLECTION = "hydrometric-monthly-mean"
      RADIUS_KM = 50
      MAX_STATIONS = 5
      TREND_HOURS = 72
      # A flow change under this share of the flow counts as steady.
      STEADY_SHARE = 0.05
      STALE_AFTER = 6 * 3600
      INPUT_SCHEMA = {
        type: "object",
        properties: {
          **Base::LOCATION_PROPERTIES,
          river: { type: "string", maxLength: 60, description: "Only gauges whose name contains this text (\"Bow River\")." },
          stations: { type: "integer", minimum: 1, maximum: MAX_STATIONS, default: 3, description: "Nearest gauges to include." },
          **Base::LANG_PROPERTY
        },
        additionalProperties: false
      }.freeze

      def call(arguments)
        lang = lang(arguments)
        point = resolve_point(arguments)
        limit = (arguments["stations"] || 3).clamp(1, MAX_STATIONS)
        filter = river_filter(arguments["river"])
        stations = gauges(point, filter, limit).then { |nearest| concurrently(nearest) { |distance, feature| gauge(feature, distance, lang) } }
        result = { location: point.to_h, gauges: stations }
        if stations.empty?
          result[:note] = "No real-time gauge#{" named like #{arguments["river"].inspect}" if filter} within #{RADIUS_KM} km."
        end
        result
      end

      private

      def river_filter(river)
        return if river.nil?
        raise InvalidArguments, "river must be text of at most 60 characters." unless river.is_a?(String) && river.length <= 60

        normalized = normalize(river)
        normalized.empty? ? nil : normalized
      end

      def gauges(point, filter, limit)
        nearest = nearest_features(STATIONS_COLLECTION, point, radius_km: RADIUS_KM, count: 500, REAL_TIME: 1, limit: 500)
        nearest = nearest.select { |_, feature| normalize(feature.dig("properties", "STATION_NAME").to_s).include?(filter) } if filter
        nearest.first(limit)
      end

      # Upper case without accents, so "riviere" matches "RIVIÈRE".
      def normalize(text) = text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").upcase.squeeze(" ").strip

      def gauge(feature, distance, lang)
        info = gauge_info(feature["properties"], distance, lang)
        number = info[:station_number]
        # The history does not depend on the readings, so both are fetched at once.
        readings, means = concurrently([-> { readings(number) }, -> { monthly_means(number, now.utc.month) }], &:call)
        return info.merge(note: "No real-time readings in the past #{TREND_HOURS / 24} days.") if readings.empty?

        latest = readings.first
        info[:note] = "The latest reading is more than #{STALE_AFTER / 3600} hours old." if now - latest[:at] > STALE_AFTER
        info.merge(latest: reading_h(latest), past_24h: change(readings, 24), past_3_days: range(readings),
                   this_month_historically: historical(means, readings))
      rescue Sources::Error => e
        info.merge(note: "This gauge's readings could not be fetched: #{e.message}")
      end

      def gauge_info(properties, distance, lang)
        number = properties["STATION_NUMBER"]
        operator = properties["CONTRIBUTOR_#{lang.upcase}"].to_s
        { name: properties["STATION_NAME"], station_number: number, province: properties["PROV_TERR_STATE_LOC"],
          operator: (operator unless operator.empty?), drainage_area_km2: properties["DRAINAGE_AREA_GROSS"]&.round,
          distance_km: round_km(distance), url: "https://wateroffice.ec.gc.ca/report/real_time_#{lang == "fr" ? "f" : "e"}.html?stn=#{number}" }
      end

      # Newest first, as {at:, level:, discharge:}.
      def readings(number)
        return [] unless number.is_a?(String)

        since = Time.at((now - (TREND_HOURS * 3600)).to_i / 3600 * 3600).utc.iso8601
        data = ogc.items(REALTIME_COLLECTION, STATION_NUMBER: number, datetime: "#{since}/..", sortby: "-DATETIME",
                                              properties: "DATETIME,LEVEL,DISCHARGE", skipGeometry: true, limit: 3000)
        readings = Array(data["features"]).filter_map do |feature|
          p = feature["properties"] || {}
          at = time(p["DATETIME"])
          { at:, level: number_or_nil(p["LEVEL"]), discharge: number_or_nil(p["DISCHARGE"]) } if at
        end
        readings.sort_by { |reading| -reading[:at].to_f }
      end

      def number_or_nil(value) = value.is_a?(Numeric) ? value.to_f : nil

      def reading_h(reading)
        { at: reading[:at].utc.iso8601, level_m: reading[:level]&.round(3), discharge_m3s: discharge(reading[:discharge]) }
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
      def historical(means, readings)
        return { note: "The historical means could not be fetched: #{means.message}" } if means.is_a?(Sources::Error)
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
      # returned, not raised, so the real-time readings are still reported.
      def monthly_means(number, month)
        return {} unless number.is_a?(String)

        data = ogc.items(MONTHLY_COLLECTION, STATION_NUMBER: number, properties: "DATE,MONTHLY_MEAN_DISCHARGE", skipGeometry: true,
                                             limit: 2000)
        Array(data["features"]).each_with_object({}) do |feature, means|
          p = feature["properties"] || {}
          year, m = p["DATE"].to_s.split("-").map(&:to_i)
          value = p["MONTHLY_MEAN_DISCHARGE"]
          means[year] = value.to_f if m == month && value.is_a?(Numeric)
        end
      rescue Sources::Error => e
        e
      end
    end
  end
end
