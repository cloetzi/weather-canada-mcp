# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Finds the AQHI location for a point: the nearest one with hourly observations, or a nearer one that only has a forecast
    # (Montréal, Québec, Gatineau, Whitehorse...).
    class AqhiLocations
      # A location near the point; observed is true when it has hourly observations.
      Found = Data.define(:distance, :feature, :observed) do
        def properties = feature["properties"]
        def id = properties["location_id"]
      end
      Nearby = Data.define(:found, :observed)

      def initialize(stations, radius_km:)
        @stations = stations
        @radius_km = radius_km
      end

      # A Nearby (the location to use and the nearest observed one), or nil when no location is in range.
      def near(lat, lon)
        observed = observed(lat, lon)
        found = [observed, forecast_only(lat, lon)].compact.min_by(&:distance)
        Nearby.new(found, observed) if found
      end

      private

      def observed(lat, lon)
        @stations.aqhi.nearest(lat, lon, count: 1, radius_km: @radius_km).first&.then { |distance, feature| Found.new(distance, feature, true) }
      end

      # Without the forecast list, none.
      def forecast_only(lat, lon)
        ids = @stations.aqhi.features.to_set { |feature| feature.dig("properties", "location_id") }
        nearest = @stations.aqhi_forecasts.nearest(lat, lon, count: 1, radius_km: @radius_km) do |feature|
          (id = feature.dig("properties", "location_id")).is_a?(String) && !ids.include?(id)
        end
        nearest.first&.then { |distance, feature| Found.new(distance, feature, false) }
      rescue Sources::Error
        nil
      end
    end
  end
end
