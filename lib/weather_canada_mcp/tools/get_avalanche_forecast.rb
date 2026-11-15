# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # The avalanche forecast covering a point, from Avalanche Canada or the partner agency that owns it.
    class GetAvalancheForecast < AvalancheBase
      NAME = "get_avalanche_forecast"
      TITLE = "Get avalanche forecast"
      DESCRIPTION = <<~TEXT.tr("\n", " ").strip
        The public avalanche forecast covering a location, as published on avalanche.ca by Avalanche Canada or the agency
        that owns it (such as Parks Canada or Avalanche Québec): the danger rating for each day in the alpine, at treeline
        and below treeline, using Avalanche Canada's own values (low, moderate, considerable, high, extreme, plus
        earlyseason, norating and noforecast, which are not danger levels); the avalanche problems with their elevations,
        aspects, likelihood and expected size; highlights, confidence, the avalanche, snowpack and weather summaries,
        and terrain and travel advice. Text is as the forecaster wrote it, with the HTML removed: quote it rather than
        reword it. Report the ratings exactly. Pass on safety_note and the forecast url. Most forecasts cover western
        Canada's mountains, Gros Morne and the Chic-Chocs in winter; get_avalanche_danger_overview lists every current one.
      TEXT
      MAX_DAYS = 3
      ASPECTS = %w[n ne e se s sw w nw].freeze
      NO_COVERAGE = {
        "en" => "No avalanche forecast covers this point. get_avalanche_danger_overview lists the regions with a current forecast.",
        "fr" => "Aucune prévision d'avalanche ne couvre ce point. get_avalanche_danger_overview liste les régions qui ont " \
                "une prévision en cours."
      }.freeze
      OUT_OF_DATE = {
        "en" => "This forecast is out of date. Check the official forecast.",
        "fr" => "Cette prévision n'est plus à jour. Consultez la prévision officielle."
      }.freeze
      PARTLY_TRANSLATED = "Part of this forecast is only available in English."
      INPUT_SCHEMA = {
        type: "object",
        properties: {
          **Base::LOCATION_PROPERTIES,
          days: { type: "integer", minimum: 1, maximum: MAX_DAYS, default: MAX_DAYS,
                  description: "Days of danger ratings to include, from today." },
          **Base::LANG_PROPERTY
        },
        additionalProperties: false
      }.freeze

      def call(arguments)
        lang = lang(arguments)
        point = resolve_point(arguments)
        days = integer_argument(arguments, "days", MAX_DAYS, 1..MAX_DAYS)
        product = avalanche.product_at(point.lat, point.lon, lang)
        return no_coverage(point, lang) unless covered?(product)

        owner = field(product, "owner", "display")
        { location: point.to_h, forecast: forecast(product, days, lang), safety_note: safety_note(lang, official_url(product["url"])),
          attribution: attribution_for("Avalanche forecast", [owner]) }
      end

      private

      # A point outside every region gets a product whose fields are all empty, never a rating.
      def covered?(product) = !product["id"].to_s.empty? && product["report"].is_a?(Hash)

      def no_coverage(point, lang)
        { location: point.to_h, forecast: nil, note: NO_COVERAGE.fetch(lang), safety_note: safety_note(lang),
          attribution: attribution_for("Avalanche forecasts", []) }
      end

      def forecast(product, days, lang)
        report = product["report"]
        ratings = danger_ratings(report, days)
        { title: report["title"], owner: field(product, "owner", "display"), url: official_url(product["url"]),
          issued_at: time(report["dateIssued"])&.utc&.iso8601, valid_until: time(report["validUntil"])&.utc&.iso8601,
          timezone: report["timezone"], note: (OUT_OF_DATE.fetch(lang) if out_of_date?(report, ratings)),
          translation_note: (PARTLY_TRANSLATED if lang == "fr" && report["isFullTranslation"] == false),
          danger_ratings: ratings, **assessment(product, report) }
      end

      # The forecaster's text and problems.
      def assessment(product, report)
        { highlights: text(report["highlights"]), confidence: confidence(report["confidence"]),
          problems: Array(report["problems"]).filter_map { |problem| problem(problem) if problem.is_a?(Hash) },
          **summaries(report["summaries"]),
          terrain_and_travel_advice: Array(report["terrainAndTravelAdvice"]).filter_map { |advice| text(advice) },
          notifications: notifications(product, report), comment: text(report["comment"]), links: links(product, report) }
      end

      # The links in the forecast text, which the text keeps only as words ("Click here for more information").
      def links(product, report)
        html = [report["highlights"], report["comment"], report["message"], *Array(report["terrainAndTravelAdvice"]),
                *Array(report["problems"]).map { |problem| field(problem, "comment") },
                *Array(report["summaries"]).map { |summary| field(summary, "content") },
                *Array(product["notifications"]).map { |item| item.is_a?(Hash) ? item["content"] || item["message"] || item["text"] : item }]
        html.flat_map { |fragment| HtmlText.links(fragment) }.uniq { |link| link[:url] }
      end

      # The days from today (in the forecast's time zone) on: a forecast issued yesterday still lists yesterday.
      def danger_ratings(report, days)
        zone = report["timezone"]
        today = LocalTime.date(now, zone)
        Array(report["dangerRatings"]).filter_map do |day|
          at = time(field(day, "date", "value")) if day.is_a?(Hash)
          next unless at && LocalTime.date(at, zone) >= today

          { date: LocalTime.date(at, zone).iso8601, day: field(day, "date", "display"),
            **BANDS.to_h { |key, band| [band, rating(field(day, "ratings", key, "rating"))] } }
        end.first(days)
      end

      def out_of_date?(report, ratings)
        valid_until = time(report["validUntil"])
        ratings.empty? || (valid_until && valid_until < now)
      end

      def confidence(value)
        return unless value.is_a?(Hash)

        { rating: field(value, "rating", "value"), display: field(value, "rating", "display"),
          statements: Array(value["statements"]).filter_map { |statement| text(statement) } }
      end

      def problem(problem)
        data = problem["data"].is_a?(Hash) ? problem["data"] : {}
        aspects = Array(data["aspects"]).filter_map { |aspect| aspect["value"] if aspect.is_a?(Hash) }
        { type: field(problem, "type", "display"), type_id: field(problem, "type", "value"),
          elevations: Array(data["elevations"]).filter_map { |elevation| elevation["display"] if elevation.is_a?(Hash) },
          aspects: ASPECTS.select { |aspect| aspects.include?(aspect) }.map(&:upcase),
          likelihood: field(data, "likelihood", "display"), likelihood_id: field(data, "likelihood", "value"),
          expected_size: expected_size(data["expectedSize"]), comment: text(problem["comment"]) }
      end

      def expected_size(value)
        return unless value.is_a?(Hash)

        { min: Float(value["min"], exception: false), max: Float(value["max"], exception: false) }
      end

      # avalanche_summary, snowpack_summary, weather_summary (and any other summary type), keyed by Avalanche Canada's type.
      def summaries(summaries)
        Array(summaries).each_with_object({}) do |summary, result|
          key = field(summary, "type", "value") if summary.is_a?(Hash)
          result[key.tr("-", "_").to_sym] = text(summary["content"]) if key.is_a?(String) && key.match?(/\A[a-z-]{1,40}\z/)
        end
      end

      def notifications(product, report)
        items = [*Array(product["notifications"]), report["message"]].filter_map do |item|
          item.is_a?(Hash) ? text(item["content"] || item["message"] || item["text"]) : text(item)
        end
        items.reject(&:empty?)
      end
    end
  end
end
