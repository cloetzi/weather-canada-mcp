# frozen_string_literal: true

module WeatherCanadaMCP
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
        name = field(entry, "product", "title") || field(entry, "area", "name")
        return unless name.is_a?(String)

        { name:, type: field(entry, "product", "type"), owner: field(entry, "owner", "display"), centroid: centroid(entry["centroid"]),
          url: official_url(entry["url"]), highest_danger: rating(entry["highestDanger"]), current_ratings: current_ratings(entry["icons"]) }
      end

      def centroid(value)
        return unless value.is_a?(Hash) && value["latitude"].is_a?(Numeric) && value["longitude"].is_a?(Numeric)

        { lat: value["latitude"].round(3), lon: value["longitude"].round(3) }
      end

      # The ratings icon in effect now.
      def current_ratings(icons)
        current = Array(icons).find do |icon|
          next false unless icon.is_a?(Hash) && icon["type"] == "ratings"

          from = time(icon["from"])
          to = time(icon["to"])
          from && to && from <= now && now < to
        end
        BANDS.to_h { |key, band| [band, field(current, "ratings", key)] } if field(current, "ratings").is_a?(Hash)
      end
    end
  end
end
