# frozen_string_literal: true

require "json"
require "uri"

module WeatherCanadaMCP
  module Sources
    module ECCC
      # MSC GeoMet WMS (geo.weather.gc.ca/geomet): the value of one layer at one point and one time, from GetFeatureInfo
      # on a 3x3 pixel map centred on the point, and a transparent PNG of one layer over an area (GetMap). GeoMet answers
      # one layer and one time step per request.
      class Wms
        PATH = "/geomet"
        LAYER = /\A[\w.-]{1,100}\z/
        # Model output changes with each run (every 6 hours or more), so an hour is fresh enough.
        TTL = 3600
        HALF_WIDTH = 0.01
        MAX_IMAGE_BYTES = 4 * 1024 * 1024

        # A point value: value is a number, label is GeoMet's class for it ("1200 - 1300", "Not Melted").
        Value = Data.define(:value, :label, :time, :reference_time)

        # image_cache holds map images apart from the small point values.
        def initialize(http:, cache:, image_cache: cache)
          @http = http
          @cache = cache
          @image_cache = image_cache
        end

        # GetMap parameters for one layer over bbox ([min_lon, min_lat, max_lon, max_lat], as Geo.bbox gives it). WMS 1.3.0
        # in EPSG:4326 takes the bbox latitude first. Shared with Sources::NRCan::Basemap, another WMS.
        def self.get_map_params(layer, bbox, width:, height:, style: "", transparent: true)
          min_lon, min_lat, max_lon, max_lat = bbox
          params = { SERVICE: "WMS", VERSION: "1.3.0", REQUEST: "GetMap", LAYERS: layer, STYLES: style.to_s, CRS: "EPSG:4326",
                     BBOX: [min_lat, min_lon, max_lat, max_lon].map { |v| v.round(5) }.join(","), WIDTH: width, HEIGHT: height,
                     FORMAT: "image/png" }
          transparent ? params.merge(TRANSPARENT: "TRUE") : params
        end

        # time is a Time (rounded to the second) or nil for the layer's default time. Returns nil when the layer has no
        # value at the point (outside the model domain).
        def feature_info(layer, lat, lon, time: nil, ttl: TTL)
          raise ArgumentError, "invalid layer" unless layer.is_a?(String) && layer.match?(LAYER)

          path = "#{PATH}?#{URI.encode_www_form(query(layer, lat, lon, time))}"
          @cache.fetch("geomet:#{path}", ttl:) do
            body = fetch(path)
            Cache::Weighed.new(parse(body, layer), body.bytesize)
          end
        end

        # PNG bytes of one layer (in one style) over bbox, [min_lon, min_lat, max_lon, max_lat] as Geo.bbox gives it.
        def get_map(layer, bbox, width:, height:, style: nil, time: nil, ttl: TTL)
          raise ArgumentError, "invalid layer" unless [layer, style || "x"].all? { |name| name.is_a?(String) && name.match?(LAYER) }

          params = self.class.get_map_params(layer, bbox, width:, height:, style:)
          params[:TIME] = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ") if time
          path = "#{PATH}?#{URI.encode_www_form(params)}"
          @image_cache.fetch("geomet:#{path}", ttl:) do
            response = response(path, accept: "image/png", max_body_bytes: MAX_IMAGE_BYTES)
            raise Sources::InvalidResponse, "geo.weather.gc.ca could not draw #{layer} for that area and time." unless response.png?

            response.body
          end
        end

        private

        def query(layer, lat, lon, time)
          bbox = [lat - HALF_WIDTH, lon - HALF_WIDTH, lat + HALF_WIDTH, lon + HALF_WIDTH].map { |v| v.round(4) }.join(",")
          params = { SERVICE: "WMS", VERSION: "1.3.0", REQUEST: "GetFeatureInfo", LAYERS: layer, QUERY_LAYERS: layer,
                     CRS: "EPSG:4326", BBOX: bbox, WIDTH: 3, HEIGHT: 3, I: 1, J: 1, INFO_FORMAT: "application/json" }
          time ? params.merge(TIME: time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")) : params
        end

        def fetch(path) = response(path, accept: "application/json").body

        def response(path, **)
          response = @http.get(:geomet, path, **)
          raise Sources::StatusError.new(response.status, "geo.weather.gc.ca") unless response.success?

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
          raise Sources::InvalidResponse, "geo.weather.gc.ca could not give a value for #{layer} at that time."
        end
      end
    end
  end
end
