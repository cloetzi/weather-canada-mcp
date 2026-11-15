# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    # Generic cell rate algorithm: on average `rate` requests per second, with bursts of up to `burst` back to back.
    # ECCC asks clients to stay well under one request per second sustained; RateLimiters keeps one per provider.
    #
    # acquire reserves the next slot before it sleeps, so fibers that call it at once are spaced out rather than
    # all waking together. Fibers only switch while sleeping, so the reservation needs no lock under one reactor;
    # the mutex covers callers on other threads (tests, the CLI).
    class RateLimiter
      # The longest a request may wait for its slot; beyond it the caller gets Sources::Busy at once.
      MAX_WAIT = 20

      def initialize(rate:, burst: 1, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: method(:sleep))
        raise ArgumentError, "rate must be positive" unless rate.positive?

        @interval = 1.0 / rate
        @tolerance = @interval * ([burst, 1].max - 1)
        @clock = clock
        @sleeper = sleeper
        @theoretical_arrival = nil
        @mutex = Thread::Mutex.new
      end

      # Returns the seconds waited. Raises Busy, without taking a slot, when the wait would exceed max_wait. A caller
      # stopped while it waits (its fiber is cancelled) gives its slot back, when no later caller has queued behind it.
      def acquire(max_wait: MAX_WAIT)
        delay, slot_end = @mutex.synchronize { reserve(max_wait) }
        waited = false
        begin
          @sleeper.call(delay) if delay.positive?
          waited = true
        ensure
          release(slot_end) unless waited
        end
        delay
      end

      private

      def reserve(max_wait)
        now = @clock.call
        arrival = [@theoretical_arrival || now, now].max
        delay = [arrival - @tolerance - now, 0.0].max
        raise Busy, delay if delay > max_wait

        @theoretical_arrival = arrival + @interval
        [delay, @theoretical_arrival]
      end

      # Slots already handed to later callers stay spent: taking one back would let two callers share a slot.
      def release(slot_end)
        @mutex.synchronize { @theoretical_arrival -= @interval if @theoretical_arrival == slot_end }
      end
    end
  end
end
