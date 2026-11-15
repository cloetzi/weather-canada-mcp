# frozen_string_literal: true

module WeatherCanadaMcp
  module Tools
    # What the Avalanche Canada tools share: the safety note every result carries, attribution naming Avalanche Canada
    # and the owning agency in place of ECCC's, and Avalanche Canada's elevation bands. These tools exist only when
    # AVALANCHE_CANADA_ENABLED is true: Avalanche Canada publishes no open licence.
    class AvalancheBase < Base
      MAP_URL = { "en" => "https://avalanche.ca/map", "fr" => "https://avalanche.ca/fr/map" }.freeze
      SAFETY_NOTE = {
        "en" => "Avalanche forecasts are regional and do not replace avalanche training, your own observations or terrain " \
                "judgement. Check the official forecast before you go: %<url>s",
        "fr" => "Les prévisions d'avalanche sont régionales et ne remplacent pas une formation en avalanche, vos propres " \
                "observations ni votre jugement du terrain. Consultez la prévision officielle avant de partir : %<url>s"
      }.freeze
      AVALANCHE_CANADA = "Avalanche Canada"
      UNOFFICIAL = "Unofficial tool, not affiliated with or endorsed by %<agencies>s."
      # Avalanche Canada's elevation bands, as its API keys them.
      BANDS = { "alp" => :alpine, "tln" => :treeline, "btl" => :below_treeline }.freeze

      class << self
        # Appended to errors: who the data is from, and the safety note.
        def attribution
          "Data Source: #{AVALANCHE_CANADA} (avalanche.ca). #{format(UNOFFICIAL, agencies: AVALANCHE_CANADA)} " \
            "#{format(SAFETY_NOTE["en"], url: MAP_URL["en"])}"
        end
      end

      private

      def avalanche = @context.avalanche

      def safety_note(lang, url = nil) = format(SAFETY_NOTE.fetch(lang), url: url || MAP_URL.fetch(lang))

      # "<what> by <owners>, via Avalanche Canada (avalanche.ca). Unofficial tool, ...": names every agency involved.
      def attribution_for(what, owners)
        owners = owners.grep(String).map(&:strip).reject(&:empty?).uniq
        others = owners - [AVALANCHE_CANADA]
        source = others.empty? ? AVALANCHE_CANADA : "#{join_names(owners)}, via #{AVALANCHE_CANADA}"
        "#{what} by #{source} (avalanche.ca). #{format(UNOFFICIAL, agencies: join_names([AVALANCHE_CANADA, *others], "or"))}"
      end

      def join_names(names, conjunction = "and")
        names.size <= 2 ? names.join(" #{conjunction} ") : "#{names[0..-2].join(", ")} #{conjunction} #{names.last}"
      end

      def text(html) = HtmlText.call(html)

      # Hash#dig that answers nil, rather than raising, when upstream data has an unexpected shape along the way.
      def field(value, *keys) = keys.reduce(value) { |current, key| current.is_a?(Hash) ? current[key] : nil }

      # A danger rating as Avalanche Canada gives it: its value (low ... extreme, earlyseason, norating, noforecast) and label.
      def rating(value) = ({ rating: value["value"], display: value["display"] } if value.is_a?(Hash))

      # Links handed to the model as official: avalanche.ca pages only.
      def official_url(value) = (value if value.is_a?(String) && value.match?(%r{\Ahttps://(www\.)?avalanche\.ca/[^\s]*\z}))

      def number(value) = (value if value.is_a?(Numeric))
    end
  end
end
