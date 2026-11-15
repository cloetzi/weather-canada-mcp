# frozen_string_literal: true

module WeatherCanadaMcp
  module Tools
    # Every current avalanche forecast product, with its highest danger and today's ratings.
    class GetAvalancheDangerOverview < AvalancheBase
      NAME = "get_avalanche_danger_overview"
      TITLE = "Get avalanche danger overview"
      DESCRIPTION = <<~TEXT.tr("\n", " ").strip
        Every avalanche forecast currently published on avalanche.ca, by Avalanche Canada and its partner agencies: the
        region name, owner, centre point, official url, the highest danger and the current rating in the alpine, at
        treeline and below treeline. Ratings are Avalanche Canada's own values (low, moderate, considerable, high,
        extreme, plus earlyseason, norating and noforecast, which are not danger levels). Use get_avalanche_forecast
        for one region's problems and advice. Pass on safety_note.
      TEXT
      INPUT_SCHEMA = { type: "object", properties: { **Base::LANG_PROPERTY }, additionalProperties: false }.freeze

      def call(arguments)
        lang = lang(arguments)
        products = avalanche.metadata(lang).filter_map { |entry| product(entry) if entry.is_a?(Hash) }
        result = { products:, safety_note: safety_note(lang),
                   attribution: attribution_for("Avalanche forecasts", products.map { |product| product[:owner] }) }
        result[:note] = "No avalanche forecast is published right now." if products.empty?
        result
      end

      private

      def product(entry)
        name = entry.dig("product", "title") || entry.dig("area", "name")
        return unless name.is_a?(String)

        { name:, type: entry.dig("product", "type"), owner: entry.dig("owner", "display"), centroid: centroid(entry["centroid"]),
          url: entry["url"], highest_danger: rating(entry["highestDanger"]), current_ratings: current_ratings(entry["icons"]) }
      end

      def centroid(value)
        return unless value.is_a?(Hash) && value["latitude"].is_a?(Numeric) && value["longitude"].is_a?(Numeric)

        { lat: value["latitude"].round(3), lon: value["longitude"].round(3) }
      end

      def rating(value) = ({ rating: value["value"], display: value["display"] } if value.is_a?(Hash))

      # The ratings icon in effect now.
      def current_ratings(icons)
        current = Array(icons).find do |icon|
          next false unless icon.is_a?(Hash) && icon["type"] == "ratings"

          from = time(icon["from"])
          to = time(icon["to"])
          from && to && from <= now && now < to
        end
        BANDS.to_h { |key, band| [band, current.dig("ratings", key)] } if current&.dig("ratings").is_a?(Hash)
      end
    end
  end
end
