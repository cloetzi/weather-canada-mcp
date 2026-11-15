# frozen_string_literal: true

require "date"

module WeatherCanadaMCP
  module Tools
    # What is normal and what is extreme for a place and date: the daily records (LTCE) of the nearest climate
    # "virtual station" and the monthly climate normals of the nearest normals station.
    class GetClimateContext < Base
      RECORDS_KM = 100
      NORMALS_KM = 50
      TEMPERATURE = "ltce-temperature"
      PRECIPITATION = "ltce-precipitation"
      SNOWFALL = "ltce-snowfall"
      NORMALS = "climate-normals"
      # Output field => climate-normals NORMAL_ID.
      NORMAL_IDS = {
        mean_temperature_c: 1, mean_daily_max_c: 5, mean_daily_min_c: 8, total_precipitation_mm: 56, rainfall_mm: 52,
        snowfall_cm: 54, days_with_precipitation: 69, days_with_rain: 61, days_with_snowfall: 65, days_with_snowfall_5cm: 66,
        mean_snow_depth_cm: 73, month_end_snow_depth_cm: 82, days_with_freezing_rain: 83, days_with_thunderstorms: 84,
        sunshine_hours: 102
      }.freeze
      DATE = /\A(?:\d{4}-)?(\d{2})-(\d{2})\z/
      tool_name "get_climate_context"
      title "Get climate normals and records"
      description <<~TEXT
        Climate context for a location and date, to judge whether a forecast is unusual: the daily records for that
        calendar day (highest and lowest temperatures, most precipitation and most snowfall, with the year of each) from
        Environment Canada's long-term climate extremes for the nearest of about 750 places (within 100 km, joining the
        records of nearby stations since as early as the 1840s; each span of records gives the years covered, with "to"
        only when the series has ended), and the monthly climate normals (1981-2010) at the nearest normals station
        (within 50 km): mean daily high and low, precipitation, rain, snowfall, days with precipitation or snow, snow
        depth and sunshine. The stations are usually in valleys and towns, so mountain
        conditions differ. date defaults to today.
      TEXT
      location_arguments
      argument :date, :string, pattern: DATE,
                               description: "The calendar day, YYYY-MM-DD or MM-DD (the year is ignored). Defaults to today."
      argument :lang, :language

      def call(args)
        lang = args.lang
        point = args.point
        month, day = month_day(args.date, point)
        bbox = Geo.snapped_bbox(point.lat, point.lon, RECORDS_KM).join(",")
        temperature, precipitation, snowfall, normals = concurrently(
          [-> { daily(TEMPERATURE, bbox, month, day) }, -> { daily(PRECIPITATION, bbox, month, day) },
           -> { daily(SNOWFALL, bbox, month, day) }, -> { normals(point, month) }], &:call
        )
        { location: point.to_h, month:, day:, daily_records: records(point, [temperature, precipitation, snowfall], lang),
          monthly_normals: normals, source_url: "https://climate.weather.gc.ca/" }
      end

      private

      # The local calendar day at the point, unless one is given.
      def month_day(date, point)
        return local_today(point) if date.nil?

        month, day = date.is_a?(String) ? date.match(DATE)&.captures&.map(&:to_i) : nil
        raise InvalidArguments, "date must be YYYY-MM-DD or MM-DD." unless month && Date.valid_date?(2000, month, day)

        [month, day]
      end

      def local_today(point)
        today = LocalTime.date(now, point.zone)
        [today.month, today.day]
      end

      def daily(collection, bbox, month, day)
        Array(ogc.items(collection, bbox:, LOCAL_MONTH: month, LOCAL_DAY: day, limit: 200)["features"])
      end

      # The records of the nearest virtual station that has temperature records (or else of the nearest with any).
      def records(point, collections, lang)
        nearest = nearest_record(collections.first, point) || nearest_record(collections.flatten, point)
        return { note: "No climate records within #{RECORDS_KM} km." } unless nearest

        distance, feature = nearest
        id = feature.dig("properties", "VIRTUAL_CLIMATE_ID")
        temperature, precipitation, snowfall = collections.map do |features|
          features.find { |entry| entry.dig("properties", "VIRTUAL_CLIMATE_ID") == id }&.dig("properties") || {}
        end
        properties = feature["properties"]
        { station: { name: properties["VIRTUAL_STATION_NAME_#{lang == "fr" ? "F" : "E"}"] || properties["VIRTUAL_STATION_NAME_E"], id:,
                     distance_km: round_km(distance) },
          **temperature_records(temperature), **amount_record(precipitation, "PRECIPITATION", "mm"),
          **amount_record(snowfall, "SNOWFALL", "cm") }
      end

      def nearest_record(features, point) = features.filter_map { |feature| located(feature, point) }.min_by(&:first)

      def located(feature, point)
        lon, lat = feature.dig("geometry", "coordinates")
        return unless lat.is_a?(Numeric) && lon.is_a?(Numeric) && feature.dig("properties", "VIRTUAL_CLIMATE_ID")

        distance = Geo.distance_km(point.lat, point.lon, lat, lon)
        [distance, feature] if distance <= RECORDS_KM
      end

      def temperature_records(row)
        return {} if row.empty?

        { temperature: { highest_max_c: record(row, "RECORD_HIGH_MAX_TEMP"), lowest_max_c: record(row, "RECORD_LOW_MAX_TEMP"),
                         max_records: span(row, "MAX_TEMP_RECORD"),
                         highest_min_c: record(row, "RECORD_HIGH_MIN_TEMP"), lowest_min_c: record(row, "RECORD_LOW_MIN_TEMP"),
                         min_records: span(row, "MIN_TEMP_RECORD") } }
      end

      # {precipitation: {most_mm:, records:}}, or snowfall with most_cm.
      def amount_record(row, element, unit)
        return {} if row.empty?

        { element.downcase.to_sym => { "most_#{unit}": record(row, "RECORD_#{element}"), records: span(row, "RECORD") } }
      end

      # The years the records cover: {from:, to:}, without to while they are still kept.
      def span(row, prefix) = { from: year(row["#{prefix}_BEGIN"]), to: year(row["#{prefix}_END"]) }

      def record(row, key)
        value = row[key]
        { value:, year: row["#{key}_YR"] } if value.is_a?(Numeric)
      end

      def year(value) = time(value)&.year

      def normals(point, month)
        directory = Sources::ECCC::StationDirectory.new(ogc:, collection: NORMALS, grid: true, MONTH: month, NORMAL_ID: 1,
                                                        properties: "STATION_NAME,CLIMATE_IDENTIFIER")
        distance, station = directory.nearest(point.lat, point.lon, count: 1, radius_km: NORMALS_KM).first
        return { note: "No climate normals station within #{NORMALS_KM} km." } unless station

        station_normals(station, distance, month)
      rescue Sources::Error => e
        { note: "The climate normals could not be fetched: #{e.message}" }
      end

      def station_normals(station, distance, month)
        id = station.dig("properties", "CLIMATE_IDENTIFIER")
        data = ogc.items(NORMALS, CLIMATE_IDENTIFIER: id, MONTH: month, skipGeometry: true, limit: 200,
                                  properties: "NORMAL_ID,VALUE,PERIOD_BEGIN,PERIOD_END")
        rows = Array(data["features"]).filter_map { |feature| feature["properties"] }.to_h { |row| [row["NORMAL_ID"], row] }
        first = rows.values.first || {}
        { station: { name: station.dig("properties", "STATION_NAME"), id:, distance_km: round_km(distance) },
          period: ("#{first["PERIOD_BEGIN"]}-#{first["PERIOD_END"]}" if first["PERIOD_BEGIN"]),
          **NORMAL_IDS.to_h { |field, normal_id| [field, rows.dig(normal_id, "VALUE")] } }
      end
    end
  end
end
