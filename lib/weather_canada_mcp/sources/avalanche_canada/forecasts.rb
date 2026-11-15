# frozen_string_literal: true

require "uri"

module WeatherCanadaMCP
  module Sources
    module AvalancheCanada
      # Avalanche Canada's forecast products and their metadata, used only when WEATHER_MCP_AVALANCHE is true. Returns
      # parsed JSON, cached per URL.
      class Forecasts < Client
        # Seconds, before WEATHER_MCP_CACHE_SCALE.
        TTLS = { product: 1200, metadata: 3600 }.freeze
        LANGS = %w[en fr].freeze

        # The forecast product covering a point. The point is rounded to 0.01 degrees (about 1 km), so nearby calls share
        # a cache entry. A point outside every forecast region returns a product with an empty id.
        def product_at(lat, lon, lang)
          query = URI.encode_www_form(lat: coordinate(lat), long: coordinate(lon))
          get(:avalanche, "/forecasts/#{check_lang(lang)}/products/point?#{query}", TTLS[:product], Hash)
        end

        # Every current forecast product, with its area, owner, highest danger and rating icons.
        def metadata(lang) = get(:avalanche, "/forecasts/#{check_lang(lang)}/metadata", TTLS[:metadata], Array)

        private

        def check_lang(lang) = LANGS.include?(lang) ? lang : raise(ArgumentError, "invalid lang")

        def coordinate(value)
          raise ArgumentError, "invalid coordinate" unless value.is_a?(Numeric) && value.to_f.finite?

          format("%.2f", value)
        end
      end
    end
  end
end
