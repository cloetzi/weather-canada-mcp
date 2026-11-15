# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    module AvalancheCanada
      # What the Avalanche Canada clients share: a cached JSON GET of either of its two origins.
      class Client
        ORIGINS = %i[avalanche avalanche_weather].freeze

        def initialize(http:, cache:)
          @json = ORIGINS.to_h { |origin| [origin, JsonClient.new(http:, cache:, origin:)] }
        end

        private

        def get(origin, path, ttl, shape) = @json.fetch(origin).get(path, ttl, shape:)
      end
    end
  end
end
