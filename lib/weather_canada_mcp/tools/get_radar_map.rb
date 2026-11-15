# frozen_string_literal: true

require "async/semaphore"

module WeatherCanadaMCP
  module Tools
    # The latest weather radar (the North American 1 km composite on GeoMet) as a map image over NRCan's base map, with
    # the rain and snow rates and the precipitation type at the point now and over the past hour.
    class GetRadarMap < Base
      RATE_LAYERS = { "rain" => "RADAR_1KM_RRAI", "snow" => "RADAR_1KM_RSNO" }.freeze
      STYLES = { "rain" => "Radar-Rain_14colors", "snow" => "Radar-Snow_14colors" }.freeze
      RATE_FIELDS = { "rain" => :rain_mm_per_h, "snow" => :snow_cm_per_h }.freeze
      LEGENDS = {
        "en" => {
          "rain" => "mm/h: light blue 0.1, cyan 1, greens 2 to 12, yellow 16, orange 24 to 32, red 50 to 64, magenta and " \
                    "purple 100 to 200",
          "snow" => "cm/h: light blue 0.1, cyan 0.3, greens 0.5 to 1, yellow 1.5, orange 2 to 3, red 4 to 5, magenta and " \
                    "purple 7.5 to 20"
        },
        "fr" => {
          "rain" => "mm/h : bleu pâle 0,1, cyan 1, verts 2 à 12, jaune 16, orange 24 à 32, rouge 50 à 64, magenta et " \
                    "violet 100 à 200",
          "snow" => "cm/h : bleu pâle 0,1, cyan 0,3, verts 0,5 à 1, jaune 1,5, orange 2 à 3, rouge 4 à 5, magenta et " \
                    "violet 7,5 à 20"
        }
      }.freeze
      TYPE_LAYER = "Radar_1km_SfcPrecipType"
      COVERAGE_LAYER = "RADAR_COVERAGE_RRAI.INV"
      COVERAGE_STYLE = "Radar-Coverage_Inv-LightGray"
      RADII = [25, 50, 100, 200].freeze
      SIZE = 512
      # Map centres are rounded to this many degrees, so nearby requests share images (in the cache and upstream).
      SNAP = 0.05
      HISTORY_MINUTES = [30, 60].freeze
      SNOW_MONTHS = [11, 12, 1, 2, 3, 4].freeze
      # The latest frame changes every 6 minutes; a given frame never changes.
      LATEST_TTL = 120
      FRAME_TTL = 3600
      # Composing is CPU work on a thread; at most this many run at once.
      tool_name "get_radar_map"
      title "Get the weather radar map"
      description <<~TEXT
        The latest weather radar around a location (updated every 6 minutes): a 512x512 PNG map of precipitation over
        a base map, the location ringed in red at its centre (or near it), plus the radar's rain rate (mm/h), snow rate
        (cm/h) at the point, the surface precipitation type detected at or next to it (left out when there is none),
        and the rate there 30 and 60 minutes ago. radius_km sets
        the area shown (25 to 200 km from the point). precipitation picks the map's colour scale, rain or snow; it
        defaults to snow from November to April. Colours run from light blue (lightest) through green, yellow, orange
        and red to purple (heaviest); light grey shading marks areas outside radar coverage. Radar can miss
        precipitation below the beam in mountains and far from radars, and can show echoes that do not reach the
        ground.
      TEXT
      location_arguments
      argument :radius_km, :integer, in: RADII, default: 100, description: "Distance from the point to the map's edges."
      argument :precipitation, :string, in: RATE_LAYERS.keys, description: "The map's colour scale: rain or snow."
      argument :include_image, :boolean, default: true,
                                         description: "Return the map image too. false gives only the readings, with fewer upstream requests."
      argument :lang, :language

      def call(args)
        point = args.point
        kind = precipitation(args.precipitation)
        latest = wms_value(RATE_LAYERS.fetch(kind), point, ttl: LATEST_TTL)
        at = time(latest&.time)
        return { location: point.to_h, note: "The radar has no image for this location right now." } unless at

        radar(args, kind, latest, at)
      end

      private

      def precipitation(kind)
        return SNOW_MONTHS.include?(now.utc.month) ? "snow" : "rain" if kind.nil?

        kind
      end

      def radar(args, kind, latest, at)
        point = args.point
        other = RATE_LAYERS.keys.find { |key| key != kind }
        bbox = Geo.bbox(snap(point.lat), snap(point.lon), args.radius_km)
        (other_rate, type, *history), images = fetch_all(args, bbox, [kind, other], at)
        data = { location: point.to_h, observed_at: at, **readings(kind, other, at, [latest, other_rate, type, history]) }
        return data.merge(map: { precipitation: kind, legend: LEGENDS.dig(args.lang, kind) }) unless args.include_image

        with_image(data, args, [kind, at, bbox], images)
      end

      def with_image(data, args, (kind, at, bbox), (radar, coverage, (base_png, base_error)))
        image = compose(args.point, bbox, [kind, at], [coverage, radar], base_png)
        data[:map] = map_info(kind, args, bbox, image.base_error || base_error)
        credits = base_png && !image.base_error ? [self.class.attribution, Sources::NRCan::Basemap::ATTRIBUTION] : []
        Result.new(data:, attributions: credits, image: Tools::Image.new(data: image.png, mime_type: "image/png"))
      end

      def compose(point, bbox, (kind, at), layers, base_png)
        marker = marker(point, bbox)
        composed([kind, at.to_i, bbox, marker, base_png ? 1 : 0]) do
          Maps::Compositor.compose(layers, width: SIZE, height: SIZE, marker:, base: base_png)
        end
      end

      def readings(kind, other, at, (latest, other_rate, type, history))
        { at_point: { RATE_FIELDS.fetch(kind) => rate(latest), RATE_FIELDS.fetch(other) => rate(other_rate),
                      precipitation_type: type&.label, precipitation_type_time: time(type&.time) },
          past_hour: HISTORY_MINUTES.zip(history).map do |minutes, found|
            { time: at - (minutes * 60), RATE_FIELDS.fetch(kind) => rate(found) }
          end }
      end

      # [[other rate, precipitation type, *rates in the past hour], [radar PNG, coverage PNG, [base map PNG, note]]]; the
      # images are left out without include_image.
      def fetch_all(args, bbox, (kind, other), at)
        values = value_tasks(args.point, kind, other, at)
        tasks = args.include_image ? values + image_tasks(bbox, kind, at) : values
        found = concurrently(tasks, &:call)
        [found.first(values.size), found.drop(values.size)]
      end

      def value_tasks(point, kind, other, at)
        layer = RATE_LAYERS.fetch(kind)
        [-> { wms_value(RATE_LAYERS.fetch(other), point, time: at, ttl: FRAME_TTL) }, -> { wms_value(TYPE_LAYER, point, ttl: LATEST_TTL) },
         *HISTORY_MINUTES.map { |minutes| -> { wms_value(layer, point, time: at - (minutes * 60), ttl: FRAME_TTL) } }]
      end

      def image_tasks(bbox, kind, at)
        map = ->(name, style) { wms.get_map(name, bbox, width: SIZE, height: SIZE, style:, time: at, ttl: FRAME_TTL) }
        [-> { map.call(RATE_LAYERS.fetch(kind), STYLES.fetch(kind)) }, -> { map.call(COVERAGE_LAYER, COVERAGE_STYLE) }, -> { base_map(bbox) }]
      end

      def snap(degrees) = ((degrees / SNAP).round * SNAP).round(2)

      def rate(found) = found&.value&.then { |number| number.round(2) }

      # Without the base map the radar is still drawn, over white.
      def base_map(bbox) = attempt { basemap.get_map(bbox, width: SIZE, height: SIZE) }

      # The pixel of the point; the map's centre is snapped, so the point can sit a little off centre.
      def marker(point, bbox)
        min_lon, min_lat, max_lon, max_lat = bbox
        [((point.lon - min_lon) / (max_lon - min_lon) * SIZE).floor.clamp(0, SIZE - 1),
         ((max_lat - point.lat) / (max_lat - min_lat) * SIZE).floor.clamp(0, SIZE - 1)]
      end

      # The composed map, made once per frame, area and marker. Decoding and encoding PNGs is CPU work, so it runs on a
      # thread (at most Application::COMPOSE_SLOTS at once) and other requests' fibers keep going.
      def composed(key, &block)
        images.fetch("radar-map:#{key.flatten.join(",")}", ttl: FRAME_TTL) do
          @context.compose_slots.acquire do
            image = Thread.new do
              Thread.current.report_on_exception = false
              block.call
            end.value
            Sources::Cache::Weighed.new(image, image.png.bytesize)
          end
        end
      end

      def map_info(kind, args, bbox, base_error)
        min_lon, min_lat, max_lon, max_lat = bbox
        info = { precipitation: kind, radius_km: args.radius_km, width: SIZE, height: SIZE,
                 bounds: { min_lat:, min_lon:, max_lat:, max_lon: }, legend: LEGENDS.dig(args.lang, kind) }
        return info unless base_error

        info.merge(note: "The base map could not be used (#{base_error}); the radar is drawn on white.")
      end
    end
  end
end
