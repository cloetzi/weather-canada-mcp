# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    module ECCC
      # The station directories the tools search, built once so each keeps its parsed list.
      Stations = Data.define(:swob, :hydrometric, :aqhi, :aqhi_forecasts) do
        def self.build(ogc:)
          new(
            swob: StationDirectory.new(ogc:, collection: "swob-stations", properties: "name,msc_id,data_provider"),
            # 2,600 real-time gauges: too many to fetch whole, so the area around the point is read.
            hydrometric: StationDirectory.new(
              ogc:, collection: "hydrometric-stations", grid: true, REAL_TIME: 1,
              properties: "STATION_NAME,STATION_NUMBER,PROV_TERR_STATE_LOC,CONTRIBUTOR_EN,CONTRIBUTOR_FR,DRAINAGE_AREA_GROSS"
            ),
            # The latest observation of each AQHI location, about 125 of them.
            aqhi: StationDirectory.new(ogc:, collection: "aqhi-observations-realtime", latest: true),
            # Every publication of every AQHI forecast (about 800 features, a location each several times): the locations that
            # have a forecast but no observation (Montréal, Québec, Gatineau, Whitehorse...) are found here.
            aqhi_forecasts: StationDirectory.new(ogc:, collection: "aqhi-forecasts-realtime", aqhi_type: "AQHI-Forecast-Period",
                                                 properties: "location_id,location_name_en,location_name_fr")
          )
        end
      end
    end
  end
end
