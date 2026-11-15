# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Current conditions, the official text forecast, hourly forecast and sun times from the nearest City Page site.
    class GetForecast < Base
      MAX_HOURS = 24
      DISTANT_SITE_KM = 50
      tool_name "get_forecast"
      title "Get the weather forecast"
      description <<~TEXT
        Environment Canada's forecast for the nearest of ~850 forecast sites: current conditions, the official
        human-written forecast by period (today, tonight, then about 6 days, including snow levels in the mountains
        where ECCC issues them), an hourly forecast, sunrise/sunset and active warning headlines. The result names the site used and its distance from the location; a site tens of km away, or at a
        different elevation, may not match conditions in the backcountry. For full alert text use get_alerts.
      TEXT
      location_arguments
      argument :hours, :integer, in: 0..MAX_HOURS, default: 12, description: "Hourly forecast entries to include (0 to omit)."
      argument :lang, :language

      def call(args)
        point = args.point
        distance, site = forecast_sites.nearest_sites(point.lat, point.lon, limit: 1).first
        properties = ogc.item(Sources::ECCC::ForecastSites::COLLECTION, site.id).fetch("properties") do
          raise Sources::InvalidResponse, "#{Sources::ECCC::ForecastSites::COLLECTION} returned a forecast without properties."
        end
        forecast = Sources::ECCC::CityPage.parse(properties, lang: args.lang)
        { location: point.to_h, forecast_site: site_info(forecast, site, distance, args.lang), **shape(forecast, args.hours) }
      end

      private

      def shape(forecast, hours)
        {
          issued_at: forecast.issued_at, warnings: forecast.warnings.map(&:to_h), current_conditions: forecast.conditions&.to_h,
          forecast: forecast.periods.map(&:to_h), hourly: (forecast.hours.first(hours).map(&:to_h) if hours.positive?),
          sun: { sunrise: forecast.sunrise, sunset: forecast.sunset }, normals: forecast.normals
        }
      end

      def site_info(forecast, site, distance, lang)
        info = { id: site.id, name: site.name_in(lang), region: site.region_in(lang), distance_km: round_km(distance),
                 lat: site.lat, lon: site.lon, url: forecast.url }
        info[:note] = "The nearest forecast site is #{round_km(distance)} km away; conditions there may differ." if distance > DISTANT_SITE_KM
        info
      end
    end
  end
end
