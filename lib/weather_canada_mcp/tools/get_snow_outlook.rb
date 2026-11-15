# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Snow level, new snow and blowing snow at a point over the next 12 to 48 hours, from the HRDPS and RDPS model
    # fields on GeoMet WMS, in four equal steps.
    class GetSnowOutlook < Base
      STEPS = 4
      # Hours ahead => hours per step. Steps line up with UTC multiples of the step, the times at which GeoMet has
      # the matching RDPS accumulation layer (RDPS_10km_Snow-Accum3h, 6h, 12h: snow over the hours before).
      STEP_HOURS = { 12 => 3, 24 => 6, 48 => 12 }.freeze
      SNOW_LEVEL = %w[HRDPS-WEonG_2.5km_SnowLevelHeight RDPS-WEonG_10km_SnowLevelHeight].freeze
      BLOWING_SNOW = "HRDPS-WEonG_2.5km_BlowingSnow-Prob"
      # GeoMet's snow level codes for "no snow level to report" (the number is not a height).
      SNOW_LEVEL_CODES = {
        -1 => { "en" => "partly melted: the snow level is close to the surface",
                "fr" => "partiellement fondue : le niveau de la neige est près de la surface" },
        -2 => { "en" => "snow to the surface: the snow level is below the ground here",
                "fr" => "neige jusqu'à la surface : le niveau de la neige est sous le sol ici" }
      }.freeze
      tool_name "get_snow_outlook"
      title "Get the snow outlook"
      description <<~TEXT
        Model guidance for snow at a point over the next 12, 24 or 48 hours, in four steps: the snow level (the height
        in metres above sea level below which snow turns to rain, from the 2.5 km HRDPS model), new snow as water
        equivalent (mm, from the 10 km RDPS model; 1 mm is roughly 1 cm of fresh snow, more in cold dry snow) and the
        probability of blowing snow. "snow to the surface" means the snow level is below the ground at this point (the
        model's terrain is smoothed over 2.5 km), so precipitation falls as snow. This is raw model output, not a forecaster's forecast and not an avalanche
        bulletin; for mountain text forecasts use get_forecast. Times are UTC (ISO 8601).
      TEXT
      location_arguments
      argument :hours, :integer, in: STEP_HOURS.keys, default: 24, description: "How far ahead to look: 12, 24 or 48 hours."
      argument :lang, :language

      def call(args)
        lang = args.lang
        point = args.point
        step = STEP_HOURS.fetch(args.hours)
        # The step that contains now comes first.
        start = Time.at(now.to_i / (step * 3600) * (step * 3600)).utc
        ends = (1..STEPS).map { |k| start + (k * step * 3600) }
        steps = concurrently(ends) { |to| step(point, to - (step * 3600), to, step, lang) }
        shape(point, steps, step)
      end

      private

      def step(point, from, to, hours, lang)
        level, snow, blowing = concurrently(
          [-> { snow_level(point, to, lang) }, -> { wms_value("RDPS_10km_Snow-Accum#{hours}h", point, time: to) },
           -> { wms_value(BLOWING_SNOW, point, time: to) }], &:call
        )
        { from: from.iso8601, to: to.iso8601, **level, new_snow_water_mm: snow&.value&.round(1),
          blowing_snow_probability_pct: blowing&.value&.round, reference_times: [level[:run], snow&.reference_time].compact }
      end

      # The HRDPS covers southern Canada; north of it the RDPS fills in. A negative value is a code, not a height; one
      # this tool does not know gives no snow level rather than the other model's.
      def snow_level(point, time, lang)
        SNOW_LEVEL.each do |layer|
          found = wms_value(layer, point, time:)
          next unless found
          return { snow_level_m: (found.value / 10.0).round * 10, run: found.reference_time } unless found.value.negative?

          code = SNOW_LEVEL_CODES[found.value.round]
          return { snow_level: code&.dig(lang), run: found.reference_time }
        end
        {}
      end

      def shape(point, steps, step)
        runs = steps.flat_map { |entry| entry.delete(:reference_times) }.uniq.sort
        steps.each { |entry| entry.delete(:run) }
        amounts = steps.filter_map { |entry| entry[:new_snow_water_mm] }
        result = { location: point.to_h, step_hours: step, steps:, total_new_snow_water_mm: (amounts.sum.round(1) if amounts.any?),
                   model_runs: runs }
        missing = steps.count { |entry| entry.except(:from, :to).values.all?(&:nil?) }
        if missing.positive?
          result[:note] = "The models have no values for #{missing} of the steps (beyond the latest run, or outside the model area)."
        end
        result
      end
    end
  end
end
