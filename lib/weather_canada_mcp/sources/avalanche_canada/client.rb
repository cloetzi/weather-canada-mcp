# frozen_string_literal: true

require "json"

module WeatherCanadaMCP
  module Sources
    module AvalancheCanada
      # What the Avalanche Canada clients share: a cached GET of one origin that parses JSON and checks its shape.
      class Client
        NAMES = { avalanche: "Avalanche Canada", avalanche_weather: "Avalanche Canada's weather station service" }.freeze

        def initialize(http:, cache:)
          @http = http
          @cache = cache
        end

        private

        def get(origin, path, ttl, shape)
          @cache.fetch("#{origin}:#{path}", ttl:) do
            response = @http.get(origin, path)
            raise StatusError.new(response.status, NAMES.fetch(origin)) unless response.success?

            parse(response.body, NAMES.fetch(origin), shape)
          end
        end

        def parse(body, name, shape)
          data = JSON.parse(body.dup.force_encoding(Encoding::UTF_8), max_nesting: 64)
          raise InvalidResponse, "#{name} returned JSON in an unexpected shape." unless data.is_a?(shape)

          data
        rescue JSON::ParserError
          raise InvalidResponse, "#{name} returned a response that is not valid JSON."
        end
      end
    end
  end
end
