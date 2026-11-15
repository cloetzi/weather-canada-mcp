# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    # One RateLimiter per data provider, so a slow Avalanche Canada never queues ECCC requests, and the other way round.
    # Each provider gets the configured rate, with a burst of BURST.
    class RateLimiters
      BURST = 12
      PROVIDERS = { eccc_api: :eccc, geomet: :eccc, cgn: :nrcan, basemap: :nrcan, avalanche: :avalanche_canada,
                    avalanche_weather: :avalanche_canada }.freeze

      # providers maps each origin to the provider whose limit it counts against.
      def initialize(rate:, burst: BURST, providers: PROVIDERS, **)
        @providers = providers
        @limiters = providers.values.uniq.to_h { |provider| [provider, RateLimiter.new(rate:, burst:, **)] }
      end

      def acquire(origin, **) = @limiters.fetch(@providers.fetch(origin)).acquire(**)
    end
  end
end
