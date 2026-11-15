# frozen_string_literal: true

module WeatherCanadaMcp
  module Upstream
    # Generic cell rate algorithm: on average `rate` requests per second, with bursts of up to `burst` back to back.
    # ECCC asks clients to stay well under one request per second sustained.
    #
    # acquire reserves the next slot before it sleeps, so fibers that call it at once are spaced out rather than
    # all waking together. Fibers only switch while sleeping, so the reservation needs no lock under one reactor;
    # the mutex covers callers on other threads (tests, the CLI).
    class RateLimiter
      def initialize(rate:, burst: 1, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: method(:sleep))
        raise ArgumentError, "rate must be positive" unless rate.positive?

        @interval = 1.0 / rate
        @tolerance = @interval * ([burst, 1].max - 1)
        @clock = clock
        @sleeper = sleeper
        @theoretical_arrival = nil
        @mutex = Thread::Mutex.new
      end

      # Returns the seconds waited.
      def acquire
        delay = @mutex.synchronize { reserve }
        @sleeper.call(delay) if delay.positive?
        delay
      end

      private

      def reserve
        now = @clock.call
        arrival = [@theoretical_arrival || now, now].max
        delay = arrival - @tolerance - now
        @theoretical_arrival = arrival + @interval
        delay.positive? ? delay : 0.0
      end
    end
  end
end
