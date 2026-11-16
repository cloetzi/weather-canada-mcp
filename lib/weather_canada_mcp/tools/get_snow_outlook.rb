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
      # The ground height of each model, in the same order: snow levels are heights above sea level, so they are read against it.
      OROGRAPHY = %w[HRDPS-WEonG_2.5km_Orography RDPS-WEonG_10km_Orography].freeze
      # Within this many metres of the snow level the precipitation type is a toss-up.
      TRANSITION_M = 100
      # GeoMet's snow level codes for "no snow level to report" (the number is not a height).
      SNOW_LEVEL_CODES = {
        -1 => { "en" => "partly melted: the snow level is close to the surface",
                "fr" => "partiellement fondue : le niveau de la neige est près de la surface" },
        -2 => { "en" => "snow to the surface: the snow level is below the ground here",
                "fr" => "neige jusqu'à la surface : le niveau de la neige est sous le sol ici" }
      }.freeze
      # Snow depth to water depth: the usual 10:1 (1 mm of water is 1 cm of snow), which the result states. Cold dry snow
      # is lighter (a higher ratio) and wet snow near freezing is denser.
      SNOW_TO_LIQUID = 10
      tool_name "get_snow_outlook"
      title "Get the snow outlook"
      description <<~TEXT
        Model guidance for snow at a point over the next 12, 24 or 48 hours, in four steps: the snow level (metres above
        sea level below which snow turns to rain, HRDPS 2.5 km), new snow as water equivalent (mm, RDPS 10 km) with an
        estimate in cm, and the probability of blowing snow. Raw model output, not a forecaster's forecast or an avalanche
        bulletin; for text forecasts use get_forecast. model_ground_elevation_m is the height of the ground in the model,
        which can differ a lot from the real terrain in the mountains: compare snow_level_m with it, or give elevation_m to
        see what falls at that height (rain below the snow level, snow above it).
      TEXT
      location_arguments
      argument :hours, :integer, in: STEP_HOURS.keys, default: 24, description: "How far ahead to look: 12, 24 or 48 hours."
      argument :elevation_m, :integer, in: 0..6000, description: "Height in metres above sea level to judge snow or rain at (a ski hill, a pass)."
      argument :lang, :language

      output :model_ground_elevation_m, :integer, "The height of the ground in the weather model at this point, in metres."
      output :elevation_m, :integer, "The height asked about."
      output :step_hours, :integer, "Hours in each step."
      output :steps, :array, "The steps, each with its snow level, new snow and blowing snow probability."
      output :total_new_snow_water_mm, :number, "New snow over all steps, as water equivalent."
      output :total_new_snow_cm_estimate, :number, "The same in cm of snow at snow_to_liquid_ratio."
      output :snow_to_liquid_ratio, :number, "Snow depth to water depth used for the cm estimates (10 means 10:1)."
      output :model_runs, :array, "The model runs the values come from."

      def call(args)
        lang = args.lang
        point = args.point
        step = STEP_HOURS.fetch(args.hours)
        ground, steps = concurrently([-> { ground_elevation(point) }, -> { steps(point, step, lang) }], &:call)
        steps.each { |entry| entry[:precipitation_at_elevation] = precipitation_at(entry, args.elevation_m) } if args.elevation_m
        shape(point, steps, step).merge(model_ground_elevation_m: ground, elevation_m: args.elevation_m).compact
      end

      private

      # The step that contains now comes first.
      def steps(point, hours, lang)
        start = Time.at(now.to_i / (hours * 3600) * (hours * 3600)).utc
        ends = (1..STEPS).map { |k| start + (k * hours * 3600) }
        concurrently(ends) { |to| step(point, to - (hours * 3600), to, hours, lang) }
      end

      def step(point, from, to, hours, lang)
        level, snow, blowing = concurrently(
          [-> { snow_level(point, to, lang) }, -> { wms_value("RDPS_10km_Snow-Accum#{hours}h", point, time: to) },
           -> { wms_value(BLOWING_SNOW, point, time: to) }], &:call
        )
        { valid_from: from, valid_until: to, **level, new_snow_water_mm: snow&.value&.round(1),
          new_snow_cm_estimate: snow&.value&.then { |water| snow_cm(water) },
          blowing_snow_probability_pct: blowing&.value&.round, reference_times: [level[:run], time(snow&.reference_time)].compact }
      end

      # The HRDPS covers southern Canada; north of it the RDPS fills in. A negative value is a code, not a height; one
      # this tool does not know gives no snow level rather than the other model's.
      def snow_level(point, time, lang)
        SNOW_LEVEL.each do |layer|
          found = wms_value(layer, point, time:)
          next unless found
          return { snow_level_m: (found.value / 10.0).round * 10, run: time(found.reference_time) } unless found.value.negative?

          code = SNOW_LEVEL_CODES[found.value.round]
          return { snow_level: code&.dig(lang), run: time(found.reference_time) }
        end
        {}
      end

      # The model's ground height at the point, to the nearest 10 m like the snow level, from the first model that covers it.
      def ground_elevation(point)
        OROGRAPHY.each do |layer|
          found = wms_value(layer, point)
          return (found.value / 10.0).round * 10 if found
        end
        nil
      end

      # Snow above the snow level and rain below it; a toss-up close to it. The codes -2 (snow to the surface) and -1
      # (partly melted, snow near the ground) have no height.
      def precipitation_at(entry, elevation)
        level = entry[:snow_level_m]
        return "snow" if level && elevation >= level + TRANSITION_M
        return "rain" if level && elevation <= level - TRANSITION_M
        return "rain or snow: close to the snow level" if level

        entry[:snow_level] ? "snow or a mix: the snow is partly melted near the ground" : nil
      end

      # Centimetres of snow for millimetres of water at SNOW_TO_LIQUID.
      def snow_cm(water_mm) = (water_mm * SNOW_TO_LIQUID / 10.0).round(1)

      def shape(point, steps, step)
        runs = steps.flat_map { |entry| entry.delete(:reference_times) }.uniq.sort
        steps.each { |entry| entry.delete(:run) }
        amounts = steps.filter_map { |entry| entry[:new_snow_water_mm] }
        result = { location: point.to_h, step_hours: step, steps:, total_new_snow_water_mm: (amounts.sum.round(1) if amounts.any?),
                   total_new_snow_cm_estimate: (snow_cm(amounts.sum) if amounts.any?),
                   snow_to_liquid_ratio: (SNOW_TO_LIQUID if amounts.any?), model_runs: runs }
        missing = steps.count { |entry| entry.except(:valid_from, :valid_until).values.all?(&:nil?) }
        if missing.positive?
          result[:note] = "The models have no values for #{missing} of the steps (beyond the latest run, or outside the model area)."
        end
        result
      end
    end
  end
end
