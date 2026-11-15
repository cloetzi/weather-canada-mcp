# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    module NRCan
      # NRCan's Canada Base Map, transportation (CBMT) WMS at maps.geogratis.gc.ca: an opaque PNG of roads, places, water
      # and terrain shading over an area, under the Open Government Licence - Canada. It changes rarely, so images are
      # kept for a week. A Sources::Wms on the :basemap origin does the fetching.
      class Basemap
        PATH = "/wms/CBMT"
        LAYER = "CBMT"
        TTL = 7 * 86_400
        MAX_BYTES = 4 * 1024 * 1024
        ATTRIBUTION = "Base map: Natural Resources Canada, Canada Base Map (CBMT), Open Government Licence - Canada."

        def self.build(http:, cache:) = new(Wms.new(http:, origin: :basemap, path: PATH, cache:))

        def initialize(wms)
          @wms = wms
        end

        # PNG bytes over bbox, [min_lon, min_lat, max_lon, max_lat] as Geo.bbox gives it.
        def get_map(bbox, width:, height:)
          @wms.get_map(LAYER, bbox, width:, height:, transparent: false, ttl: TTL, max_bytes: MAX_BYTES)
        end
      end
    end
  end
end
