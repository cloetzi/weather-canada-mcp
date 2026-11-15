# frozen_string_literal: true

require "json"
require "uri"

module WeatherCanadaMCP
  module Sources
    # A WMS 1.3.0 service (GeoMet, NRCan's base map): the value of one layer at one point and one time, from GetFeatureInfo
    # on a 3x3 pixel map centred on the point, and a PNG of one layer over an area (GetMap). Errors come as XML with a 200,
    # which are told from images by their signature.
    class Wms
      # Model output changes with each run (every 6 hours or more), so an hour is fresh enough.
      TTL = 3600
      HALF_WIDTH = 0.01
      # Points are snapped to this many degrees (about 1 km), so nearby points share cache entries.
      POINT_STEP = 0.01
      MAX_IMAGE_BYTES = 4 * 1024 * 1024
      LAYER = /\A[\w.-]{1,100}\z/

      # A point value: value is a number, label is the service's class for it ("1200 - 1300", "Not Melted").
      Value = Data.define(:value, :label, :time, :reference_time)

      # origin is the key of the upstream and path the service's path on it. image_cache holds map images apart from the
      # small point values.
      def initialize(http:, origin:, path:, cache:, image_cache: cache)
        @http = http
        @origin = http.origin(origin)
        @path = path
        @cache = cache
        @image_cache = image_cache
      end

      # time is a Time (rounded to the second) or nil for the layer's default time. Returns nil when the layer has no
      # value at the point (outside the model domain).
      def feature_info(layer, lat, lon, time: nil, ttl: TTL)
        check(layer)
        path = "#{@path}?#{URI.encode_www_form(feature_params(layer, snap(lat), snap(lon), time))}"
        @cache.fetch("#{@origin.key}:#{path}", ttl:) do
          body = fetch(path, accept: "application/json").body
          Cache::Weighed.parsed(parse(body, layer), body)
        end
      end

      # PNG bytes of one layer (in one style) over bbox, [min_lon, min_lat, max_lon, max_lat] as Geo.bbox gives it. Without
      # transparent the image is opaque (a base map).
      def get_map(layer, bbox, width:, height:, style: nil, time: nil, transparent: true, ttl: TTL, max_bytes: MAX_IMAGE_BYTES)
        [layer, style || "x"].each { |name| check(name) }
        params = map_params(layer, bbox, width:, height:, style:, transparent:)
        params[:TIME] = format_time(time) if time
        path = "#{@path}?#{URI.encode_www_form(params)}"
        @image_cache.fetch("#{@origin.key}:#{path}", ttl:) do
          response = fetch(path, accept: "image/png", max_body_bytes: max_bytes)
          raise InvalidResponse, "#{@origin.label} could not draw #{layer} for that area and time." unless response.png?

          response.body
        end
      end

      private

      def check(name) = (raise ArgumentError, "invalid layer" unless name.is_a?(String) && name.match?(LAYER))

      def snap(degrees) = (degrees / POINT_STEP).round * POINT_STEP

      def format_time(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

      # WMS 1.3.0 in EPSG:4326 takes the bbox latitude first.
      def map_params(layer, bbox, width:, height:, style:, transparent:)
        min_lon, min_lat, max_lon, max_lat = bbox
        params = { SERVICE: "WMS", VERSION: "1.3.0", REQUEST: "GetMap", LAYERS: layer, STYLES: style.to_s, CRS: "EPSG:4326",
                   BBOX: [min_lat, min_lon, max_lat, max_lon].map { |v| v.round(5) }.join(","), WIDTH: width, HEIGHT: height,
                   FORMAT: "image/png" }
        transparent ? params.merge(TRANSPARENT: "TRUE") : params
      end

      def feature_params(layer, lat, lon, time)
        bbox = [lat - HALF_WIDTH, lon - HALF_WIDTH, lat + HALF_WIDTH, lon + HALF_WIDTH].map { |v| v.round(4) }.join(",")
        params = { SERVICE: "WMS", VERSION: "1.3.0", REQUEST: "GetFeatureInfo", LAYERS: layer, QUERY_LAYERS: layer,
                   CRS: "EPSG:4326", BBOX: bbox, WIDTH: 3, HEIGHT: 3, I: 1, J: 1, INFO_FORMAT: "application/json" }
        time ? params.merge(TIME: format_time(time)) : params
      end

      def fetch(path, **)
        response = @http.get(@origin.key, path, **)
        raise StatusError.new(response.status, @origin.label) unless response.success?

        response
      end

      # GeoMet reports errors (a time outside the layer's range, say) as a 200 with an XML exception report.
      def parse(body, layer)
        data = JSON.parse(body.dup.force_encoding(Encoding::UTF_8), max_nesting: 32)
        properties = data.is_a?(Hash) ? Array(data["features"]).first&.dig("properties") : nil
        return unless properties.is_a?(Hash) && properties["value"].is_a?(Numeric)

        Value.new(value: properties["value"], label: properties["class"], time: properties["time"],
                  reference_time: properties["dim_reference_time"])
      rescue JSON::ParserError
        raise InvalidResponse, "#{@origin.label} could not give a value for #{layer} at that time."
      end
    end
  end
end
