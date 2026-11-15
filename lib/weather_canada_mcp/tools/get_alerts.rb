# frozen_string_literal: true

require "time"

module WeatherCanadaMCP
  module Tools
    # Active ECCC weather alerts whose area covers a point, from the OGC API weather-alerts collection.
    class GetAlerts < Base
      NAME = "get_alerts"
      TITLE = "Get weather alerts"
      DESCRIPTION = <<~TEXT.tr("\n", " ").strip
        Active Environment Canada weather alerts (warnings, watches, advisories and statements) for a location, with
        the official alert text exactly as issued. Alerts whose area contains the point are in "alerts"; alerts for
        areas within a few km (for example a coastline or a neighbouring zone) are listed briefly in "nearby_alerts".
        An empty "alerts" list means ECCC has no alert in effect there right now. Quote alert text as given; do not
        reword or shorten safety instructions. Times are UTC (ISO 8601).
      TEXT
      COLLECTION = "weather-alerts"
      NEARBY_KM = 5
      MAX_FEATURES = 100
      INPUT_SCHEMA = {
        type: "object",
        properties: { **Base::LOCATION_PROPERTIES, **Base::LANG_PROPERTY },
        additionalProperties: false
      }.freeze

      def call(arguments)
        lang = lang(arguments)
        point = resolve_point(arguments)
        data = ogc.items(COLLECTION, bbox: Geo.bbox(point.lat, point.lon, NEARBY_KM).join(","), limit: MAX_FEATURES)
        active = Array(data["features"]).select { |feature| active?(feature["properties"]) }
        covering, nearby = active.partition { |feature| Geo.contains?(feature["geometry"], point.lat, point.lon) }
        {
          location: point.to_h,
          alerts: covering.map { |feature| alert(feature, lang) }.sort_by { |alert| severity_order(alert) },
          nearby_alerts: nearby.map { |feature| brief(feature, lang) }.uniq,
          source_url: lang == "fr" ? "https://meteo.gc.ca/warnings/index_f.html" : "https://weather.gc.ca/warnings/index_e.html"
        }
      end

      private

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
        p = feature["properties"]
        {
          headline: field(p, "alert_name", lang), type: p["alert_type"], code: p["alert_code"],
          colour: field(p, "risk_colour", lang), status: field(p, "status", lang),
          area: field(p, "feature_name", lang), province: p["province"],
          issued_at: p["publication_datetime"], valid_from: p["validity_datetime"], event_ends_at: p["event_end_datetime"],
          expires_at: p["expiration_datetime"],
          confidence: field(p, "confidence", lang), impact: field(p, "impact", lang),
          text: field(p, "alert_text", lang)
        }
      end

      def brief(feature, lang)
        p = feature["properties"]
        { headline: field(p, "alert_name", lang), type: p["alert_type"], area: field(p, "feature_name", lang),
          expires_at: p["expiration_datetime"] }
      end

      def field(properties, name, lang) = properties["#{name}_#{lang}"] || properties["#{name}_en"]

      def severity_order(alert) = [SEVERITY.fetch(alert[:type], 9), alert[:issued_at].to_s]
    end
  end
end
