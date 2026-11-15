# frozen_string_literal: true

module WeatherCanadaMcp
  module Tools
    # The latest weather radar (the North American 1 km composite on GeoMet) as a map image over NRCan's base map, with
    # the rain and snow rates and the precipitation type at the point now and over the past hour.
    class GetRadarMap < Base
      NAME = "get_radar_map"
      TITLE = "Get the weather radar map"
      DESCRIPTION = <<~TEXT.tr("\n", " ").strip
        The latest weather radar around a location (updated every 6 minutes): a 512x512 PNG map of precipitation over
        a base map, the location ringed in red at its centre (or near it), plus the radar's rain rate (mm/h), snow rate
        (cm/h) at the point, the surface precipitation type detected at or next to it (left out when there is none),
        and the rate there 30 and 60 minutes ago. radius_km sets
        the area shown (25 to 200 km from the point). precipitation picks the map's colour scale, rain or snow; it
        defaults to snow from November to April. Colours run from light blue (lightest) through green, yellow, orange
        and red to purple (heaviest); light grey shading marks areas outside radar coverage. Radar can miss
        precipitation below the beam in mountains and far from radars, and can show echoes that do not reach the
        ground. Times are UTC (ISO 8601).
      TEXT
      RATE_LAYERS = { "rain" => "RADAR_1KM_RRAI", "snow" => "RADAR_1KM_RSNO" }.freeze
      STYLES = { "rain" => "Radar-Rain_14colors", "snow" => "Radar-Snow_14colors" }.freeze
      RATE_FIELDS = { "rain" => :rain_mm_per_h, "snow" => :snow_cm_per_h }.freeze
      LEGENDS = {
        "rain" => "mm/h: light blue 0.1, cyan 1, greens 2 to 12, yellow 16, orange 24 to 32, red 50 to 64, magenta and " \
                  "purple 100 to 200",
        "snow" => "cm/h: light blue 0.1, cyan 0.3, greens 0.5 to 1, yellow 1.5, orange 2 to 3, red 4 to 5, magenta and " \
                  "purple 7.5 to 20"
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
      INPUT_SCHEMA = {
        type: "object",
        properties: {
          **Base::LOCATION_PROPERTIES,
          radius_km: { type: "integer", enum: RADII, default: 100, description: "Distance from the point to the map's edges." },
          precipitation: { type: "string", enum: RATE_LAYERS.keys, description: "The map's colour scale: rain or snow." },
          **Base::LANG_PROPERTY
        },
        additionalProperties: false
      }.freeze

      def call(arguments)
        lang(arguments)
        point = resolve_point(arguments)
        radius = arguments["radius_km"] || 100
        raise InvalidArguments, "radius_km must be one of #{RADII.join(", ")}." unless RADII.include?(radius)

        kind = precipitation(arguments["precipitation"])
        latest = value(RATE_LAYERS.fetch(kind), point, nil, LATEST_TTL)
        at = time(latest&.time)
        return { location: point.to_h, note: "The radar has no image for this location right now." } unless at

        radar(point, radius, kind, latest, at)
      end

      private

      def precipitation(kind)
        return SNOW_MONTHS.include?(now.utc.month) ? "snow" : "rain" if kind.nil?
        raise InvalidArguments, "precipitation must be rain or snow." unless RATE_LAYERS.key?(kind)

        kind
      end

      def radar(point, radius, kind, latest, at)
        bbox = Geo.bbox(snap(point.lat), snap(point.lon), radius)
        other = RATE_LAYERS.keys.find { |key| key != kind }
        other_rate, type, *history, radar, coverage, base = fetch_all(point, bbox, kind, other, at)
        {
          location: point.to_h, radar_time: at.utc.iso8601, **readings(kind, other, at, [latest, other_rate, type, history]),
          map: map_info(kind, radius, bbox, base),
          image: Tools::Image.new(data: compose([base, coverage, radar], marker(point, bbox)), mime_type: "image/png")
        }
      end

      def readings(kind, other, at, (latest, other_rate, type, history))
        { at_point: { RATE_FIELDS.fetch(kind) => rate(latest), RATE_FIELDS.fetch(other) => rate(other_rate),
                      precipitation_type: type&.label, precipitation_type_time: type&.time },
          past_hour: HISTORY_MINUTES.zip(history).map do |minutes, found|
            { time: (at - (minutes * 60)).utc.iso8601, RATE_FIELDS.fetch(kind) => rate(found) }
          end }
      end

      # [other rate, precipitation type, *rates in the past hour, radar PNG, coverage PNG, base map PNG or its error].
      def fetch_all(point, bbox, kind, other, at)
        layer = RATE_LAYERS.fetch(kind)
        map = ->(name, style) { wms.get_map(name, bbox, width: SIZE, height: SIZE, style:, time: at, ttl: FRAME_TTL) }
        concurrently(
          [-> { value(RATE_LAYERS.fetch(other), point, at, FRAME_TTL) }, -> { value(TYPE_LAYER, point, nil, LATEST_TTL) },
           *HISTORY_MINUTES.map { |minutes| -> { value(layer, point, at - (minutes * 60), FRAME_TTL) } },
           -> { map.call(layer, STYLES.fetch(kind)) }, -> { map.call(COVERAGE_LAYER, COVERAGE_STYLE) }, -> { base_map(bbox) }], &:call
        )
      end

      def snap(degrees) = ((degrees / SNAP).round * SNAP).round(2)

      # nil when the radar has no value there or then.
      def value(layer, point, time, ttl)
        wms.feature_info(layer, point.lat, point.lon, time:, ttl:)
      rescue Sources::InvalidResponse
        nil
      end

      def rate(found) = found&.value&.then { |number| number.round(2) }

      # Without the base map the radar is still drawn, over white.
      def base_map(bbox)
        basemap.get_map(bbox, width: SIZE, height: SIZE)
      rescue Sources::Error => e
        e
      end

      # The pixel of the point; the map's centre is snapped, so the point can sit a little off centre.
      def marker(point, bbox)
        min_lon, min_lat, max_lon, max_lat = bbox
        [((point.lon - min_lon) / (max_lon - min_lon) * SIZE).floor.clamp(0, SIZE - 1),
         ((max_lat - point.lat) / (max_lat - min_lat) * SIZE).floor.clamp(0, SIZE - 1)]
      end

      # Decoding and encoding PNGs is CPU work, so it runs on a thread and other requests' fibers keep going.
      def compose(layers, marker)
        layers = layers.grep(String)
        Thread.new do
          Thread.current.report_on_exception = false
          MapImage.compose(layers, width: SIZE, height: SIZE, marker:)
        end.value
      end

      def map_info(kind, radius, bbox, base)
        min_lon, min_lat, max_lon, max_lat = bbox
        info = { precipitation: kind, radius_km: radius, width: SIZE, height: SIZE,
                 bounds: { min_lat:, min_lon:, max_lat:, max_lon: }, legend: LEGENDS.fetch(kind) }
        return info.merge(base_map: Sources::Basemap::ATTRIBUTION) if base.is_a?(String)

        info.merge(note: "The base map could not be fetched (#{base.message}); the radar is drawn on white.")
      end
    end
  end
end
