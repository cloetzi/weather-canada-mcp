# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # The Air Quality Health Index (AQHI) observed and forecast at the nearest AQHI location, with Health Canada's
    # messages for the risk category.
    class GetAirQuality < Base
      FORECASTS_COLLECTION = "aqhi-forecasts-realtime"
      RADIUS_KM = 100
      STALE_AFTER = 3 * 3600
      PERIODS = %w[period_1 period_2 period_3 period_4 period_5].freeze
      # Health messages by risk category, word for word as canada.ca's "About the AQHI" page gives them (MESSAGES_URL),
      # with a capital and a full stop added. "Envisagez réduire" is the page's own wording. Low risk has one message for
      # everyone.
      MESSAGES_URL = {
        "en" => "https://www.canada.ca/en/environment-climate-change/services/air-quality-health-index/about.html",
        "fr" => "https://www.canada.ca/fr/environnement-changement-climatique/services/cote-air-sante/a-propos.html"
      }.freeze
      MESSAGES = {
        "en" => {
          "low" => { general: "Enjoy your usual outdoor activities.", at_risk: "Enjoy your usual outdoor activities." },
          "moderate" => {
            general: "Continue usual outdoor activities unless you have symptoms like coughing and throat irritation.",
            at_risk: "Consider reducing or rescheduling strenuous outdoor activities if you have symptoms like coughing " \
                     "or throat irritation."
          },
          "high" => {
            general: "Consider reducing or rescheduling strenuous outdoor activities if you have symptoms like coughing " \
                     "and throat irritation.",
            at_risk: "Reduce or reschedule strenuous outdoor activities."
          },
          "very high" => {
            general: "Reduce or reschedule strenuous outdoor activities, especially if you have symptoms like coughing " \
                     "and throat irritation.",
            at_risk: "Avoid strenuous activities outdoors."
          }
        },
        "fr" => {
          "low" => { general: "Profitez de vos activités habituelles en plein air.",
                     at_risk: "Profitez de vos activités habituelles en plein air." },
          "moderate" => {
            general: "Poursuivez vos activités habituelles en plein air, sauf si vous ressentez des symptômes comme de " \
                     "la toux ou une irritation de la gorge.",
            at_risk: "Envisagez réduire ou reporter les activités exténuantes en plein air si vous ressentez des " \
                     "symptômes comme de la toux ou une irritation de la gorge."
          },
          "high" => {
            general: "Envisagez réduire ou reporter les activités exténuantes en plein air si vous ressentez des " \
                     "symptômes comme de la toux et une irritation de la gorge.",
            at_risk: "Réduisez ou reportez les activités exténuantes en plein air."
          },
          "very high" => {
            general: "Réduisez ou reportez les activités exténuantes en plein air, particulièrement si vous ressentez " \
                     "des symptômes comme de la toux et une irritation de la gorge.",
            at_risk: "Évitez les activités exténuantes en plein air."
          }
        }
      }.freeze
      RISK_FR = { "low" => "faible", "moderate" => "modéré", "high" => "élevé", "very high" => "très élevé" }.freeze
      tool_name "get_air_quality"
      title "Get air quality"
      description <<~TEXT
        The Air Quality Health Index (AQHI, 1 to 10+, higher is worse) at the nearest AQHI location (within 100 km): the
        latest hourly observation and the forecast for today, tonight, tomorrow and later, each with its risk category and
        health messages for the general population and for people at risk.
      TEXT
      location_arguments
      argument :lang, :language

      output :aqhi_location, :object, "The AQHI location used."
      output :current, :object, "The latest hourly observation."
      output :forecast, :object, "The AQHI forecast."
      output :health_messages, :object, "Health messages, once per risk category."
      output :health_messages_source, :string, "Where the health messages come from."
      output :source_url, :string, "The official AQHI page."

      def call(args)
        lang = args.lang
        point = args.point
        distance, observation = stations.aqhi.nearest(point.lat, point.lon, count: 1, radius_km: RADIUS_KM).first
        return { location: point.to_h, note: "No AQHI location within #{RADIUS_KM} km. AQHI covers mostly populated areas." } unless observation

        properties = observation["properties"]
        current = current(properties, lang)
        forecast = forecast(properties["location_id"], lang)
        {
          location: point.to_h,
          aqhi_location: { id: properties["location_id"], name: properties["location_name_#{lang}"] || properties["location_name_en"],
                           distance_km: round_km(distance), lat: coordinates_of(observation)&.last, lon: coordinates_of(observation)&.first },
          current:, forecast:,
          health_messages: health_messages([current, *forecast&.dig(:periods)], lang), health_messages_source: MESSAGES_URL.fetch(lang),
          source_url: lang == "fr" ? "https://meteo.gc.ca/airquality/pages/index_f.html" : "https://weather.gc.ca/airquality/pages/index_e.html"
        }
      end

      private

      def coordinates_of(feature)
        lon, lat = feature.dig("geometry", "coordinates")
        [lon, lat] if lon.is_a?(Numeric) && lat.is_a?(Numeric)
      end

      def current(observation, lang)
        observed_at = time(observation["observation_datetime"])
        notes = observation["special_notes_#{lang}"].to_s.strip
        result = { observed_at:, **index(observation["aqhi"], lang), special_notes: notes.empty? ? nil : notes }
        result[:note] = "The latest observation is more than #{STALE_AFTER / 3600} hours old." if observed_at && now - observed_at > STALE_AFTER
        result
      end

      def forecast(location_id, lang)
        return unless location_id.is_a?(String)

        data = ogc.items(FORECASTS_COLLECTION, location_id:, aqhi_type: "AQHI-Forecast-Period", sortby: "-publication_datetime",
                                               skipGeometry: true, limit: 1)
        properties = Array(data["features"]).first&.dig("properties")
        return unless properties.is_a?(Hash)

        { issued_at: time(properties["publication_datetime"]), periods: periods(properties["forecast_period"], lang) }
      rescue Sources::Error => e
        { note: "The forecast could not be fetched: #{e.message}" }
      end

      def periods(forecast, lang)
        PERIODS.filter_map do |key|
          period = forecast.is_a?(Hash) ? forecast[key] : nil
          next unless period.is_a?(Hash) && period["aqhi"].is_a?(Numeric)

          { period: period["forecast_period_#{lang}"] || period["forecast_period_en"], **index(period["aqhi"], lang),
            aqhi_in_smoke: period["aqhi_insmoke"] }
        end
      end

      def index(value, lang)
        return { aqhi: nil } unless value.is_a?(Numeric)

        category = risk(value.round)
        { aqhi: value.round(1), aqhi_display: value.round > 10 ? "10+" : value.round.to_s, risk: label(category, lang) }
      end

      # The messages for each risk category that appears, once each, keyed by the risk label.
      def health_messages(entries, lang)
        risks = entries.filter_map { |entry| entry&.dig(:risk) }.uniq
        MESSAGES.fetch(lang).filter_map do |category, messages|
          [label(category, lang), messages] if risks.include?(label(category, lang))
        end.to_h
      end

      def label(category, lang) = lang == "fr" ? RISK_FR.fetch(category) : category

      def risk(rounded)
        if rounded <= 3 then "low"
        elsif rounded <= 6 then "moderate"
        elsif rounded <= 10 then "high"
        else "very high"
        end
      end
    end
  end
end
