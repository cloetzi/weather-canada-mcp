# frozen_string_literal: true

require "uri"

module WeatherCanadaMCP
  module Sources
    module NRCan
      # NRCan's Canada Base Map, transportation (CBMT) WMS at maps.geogratis.gc.ca: an opaque PNG of roads, places, water
      # and terrain shading over an area, under the Open Government Licence - Canada. It changes rarely, so images are
      # kept for a week.
      class Basemap
        PATH = "/wms/CBMT"
        TTL = 7 * 86_400
        MAX_BYTES = 4 * 1024 * 1024
        ATTRIBUTION = "Base map: Natural Resources Canada, Canada Base Map (CBMT), Open Government Licence - Canada."

        def initialize(http:, cache:)
          @http = http
          @cache = cache
        end

        # PNG bytes over bbox, [min_lon, min_lat, max_lon, max_lat] as Geo.bbox gives it.
        def get_map(bbox, width:, height:)
          params = ECCC::Wms.get_map_params("CBMT", bbox, width:, height:, transparent: false)
          path = "#{PATH}?#{URI.encode_www_form(params)}"
          @cache.fetch("basemap:#{path}", ttl: TTL) do
            response = @http.get(:basemap, path, accept: "image/png", max_body_bytes: MAX_BYTES)
            raise Sources::StatusError.new(response.status, "maps.geogratis.gc.ca") unless response.success?
            raise Sources::InvalidResponse, "maps.geogratis.gc.ca did not return a map image." unless response.png?

            response.body
          end
        end
      end
    end
  end
end
