# frozen_string_literal: true

require "time"

module WeatherCanadaMCP
  module Tools
    # Active ECCC weather alerts whose area covers a point, from the OGC API weather-alerts collection.
    class GetAlerts < Base
      COLLECTION = "weather-alerts"
      NEARBY_KM = 5
      MAX_FEATURES = 100
      tool_name "get_alerts"
      title "Get weather alerts"
      description <<~TEXT
        Active Environment Canada weather alerts (warnings, watches, advisories, statements) for a location, with the
        official text as issued. "alerts" are those whose area contains the point; "nearby_alerts" are brief entries for
        areas within a few km. An empty "alerts" list means none in effect. Quote alert text as given; do not reword or shorten safety instructions.
      TEXT
      location_arguments
      argument :lang, :language

      output :alerts, :array, "Alerts whose area contains the point, most severe first."
      output :nearby_alerts, :array, "Brief entries for alerts in areas within a few km."
      output :source_url, :string, "The official alerts page."

      def call(args)
        lang = @lang = args.lang
        point = args.point
        data = ogc.items(COLLECTION, bbox: Geo.bbox(point.lat, point.lon, NEARBY_KM).join(","), limit: MAX_FEATURES)
        active = Array(data["features"]).select { |feature| active?(feature["properties"]) }
        covering, nearby = active.partition { |feature| Geo.contains?(feature["geometry"], point.lat, point.lon) }
        {
          location: point.to_h,
          alerts: covering.map { |feature| alert(feature, lang) }.sort_by { |alert| severity_order(alert) },
          nearby_alerts: nearby.map { |feature| brief(feature, lang) }.uniq,
          source_url: source_url(lang)
        }
      end

      private

      # A stale list could miss an alert issued since, so it says so in capitals and points to the official page. Other
      # stale data (the forecast site list that gives the time zone) is noted as usual.
      def stale_note(stale, zone)
        alerts, others = stale.partition { |entry| entry.key.include?("/collections/#{COLLECTION}/") }
        return super(others, zone) if alerts.empty?

        at = LocalTime.iso8601(alerts.map(&:at).min, zone)
        note = "ALERTS COULD NOT BE REFRESHED: the alert service could not be reached, so these alerts are the ones from #{at} " \
               "and may be out of date; an alert may have been issued or ended since. Check #{source_url(@lang)} before relying on this."
        others.empty? ? note : "#{note} #{super(others, zone)}"
      end

      def source_url(lang) = lang == "fr" ? "https://meteo.gc.ca/warnings/index_f.html" : "https://weather.gc.ca/warnings/index_e.html"

      SEVERITY = { "warning" => 0, "watch" => 1, "advisory" => 2, "statement" => 3 }.freeze
      private_constant :SEVERITY

      # ECCC keeps an alert in the collection for a while after it ends; ended or expired alerts are not in effect.
      def active?(properties)
        return false unless properties.is_a?(Hash)
        return false if properties["status_en"] == "ended"

        expires = time(properties["expiration_datetime"])
        expires.nil? || expires > now
      end

      def alert(feature, lang)
        properties = feature["properties"]
        {
          headline: field(properties, "alert_name", lang), type: properties["alert_type"], code: properties["alert_code"],
          colour: field(properties, "risk_colour", lang), status: field(properties, "status", lang),
          area: field(properties, "feature_name", lang), province: properties["province"],
          issued_at: time(properties["publication_datetime"]), valid_from: time(properties["validity_datetime"]),
          event_ends_at: time(properties["event_end_datetime"]), expires_at: time(properties["expiration_datetime"]),
          confidence: field(properties, "confidence", lang), impact: field(properties, "impact", lang),
          text: field(properties, "alert_text", lang)
        }
      end

      def brief(feature, lang)
        properties = feature["properties"]
        { headline: field(properties, "alert_name", lang), type: properties["alert_type"], area: field(properties, "feature_name", lang),
          expires_at: time(properties["expiration_datetime"]) }
      end

      def field(properties, name, lang) = properties["#{name}_#{lang}"] || properties["#{name}_en"]

      def severity_order(alert) = [SEVERITY.fetch(alert[:type], 9), alert[:issued_at].to_i]
    end
  end
end
