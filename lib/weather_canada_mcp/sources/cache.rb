# frozen_string_literal: true

require "async/promise"

module WeatherCanadaMCP
  module Sources
    # In-process TTL cache keyed by request URL. Concurrent misses for the same key run the block once: the other
    # callers wait for its result (or its error, which is not cached). Meant for one reactor thread.
    #
    # Bounded twice: by entry count and by a byte budget, where an entry weighs about its size in memory (a block returns
    # a Weighed for that; a String weighs its own size). When over either bound the expired entries go first, then the
    # least recently used. Stored values are frozen, so a caller cannot change what the next one reads.
    #
    # An expired entry is kept for a grace period (as long as its TTL, at most MAX_STALE seconds). When the refresh of a
    # key that names its source fails with a Sources::Error, that stale value is returned and noted in the call's Trace.
    class Cache
      # retry_at: until then a stale entry is served without asking the upstream again (set by a failed refresh).
      Entry = Data.define(:value, :expires_at, :stale_until, :stored_at, :weight, :retry_at)
      # What a refresh that failed leaves for the callers waiting on it.
      Stale = Data.define(:entry, :source, :key)
      MAX_STALE = 6 * 3600
      # After a failed refresh the stale value is served for this long (at most the entry's TTL) before the upstream is tried
      # again, so a service that is down is not asked, and waited for, on every call.
      HOLD_OFF = 10

      # A value and the memory it takes, in bytes.
      Weighed = Data.define(:value, :bytes) do
        # A value parsed from a response body: Ruby's hashes, arrays and strings take several times the JSON text.
        def self.parsed(value, body) = new(value, body.bytesize * PARSED_FACTOR)
      end
      PARSED_FACTOR = 4

      DEFAULT_WEIGHT = 1024

      def initialize(max_entries: 512, max_bytes: 64 * 1024 * 1024, scale: 1.0, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     wall_clock: -> { Time.now })
        @max_entries = max_entries
        @max_bytes = max_bytes
        @scale = scale
        @clock = clock
        @wall_clock = wall_clock
        @entries = {}
        @bytes = 0
        @pending = {}
      end

      attr_reader :bytes

      # ttl is in seconds before scaling; a scale of 0 disables caching (but still coalesces concurrent calls). source names
      # the provider in the note that goes with a stale value; without one, a failed refresh raises.
      def fetch(key, ttl:, source: nil, &)
        entry = @entries.delete(key)
        now = @clock.call
        if entry && entry.expires_at > now
          @entries[key] = entry # most recently used goes last
          return entry.value
        end
        if entry
          @bytes -= entry.weight
          entry = nil if entry.stale_until <= now
        end
        return held(key, entry, source) if entry && source && entry.retry_at > now

        waiter = @pending[key]
        return served(waiter.wait) if waiter

        served(load(key, ttl, entry, source, &))
      end

      def size = @entries.size

      def clear
        @entries.clear
        @bytes = 0
      end

      private

      def load(key, ttl, stale, source)
        loaded = false
        promise = Async::Promise.new
        @pending[key] = promise
        value, weight = unwrap(yield)
        value = deep_freeze(value)
        store(key, value, weight, ttl * @scale)
        promise.resolve(value)
        loaded = true
        value
      rescue Sources::Error => e
        fallback = fall_back(promise, key, ttl, stale, source) if e.unreachable?
        promise.reject(e) unless fallback
        raise unless fallback

        fallback
      rescue StandardError
        # Another caller's own failure (its deadline ran out) is not what the callers waiting on it should be told.
        promise.reject(Sources::Error.new("The request was cancelled; retry it."))
        raise
      ensure
        # A loader stopped by something other than a StandardError (Async::Stop when its client goes away) must still
        # release the fibers waiting on it.
        promise.reject(Sources::Error.new("The request was cancelled; retry it.")) unless promise.resolved?
        # A refresh that was stopped (a deadline, a client that left) does not lose the stale copy.
        restore(key, stale) if stale && !loaded && !@entries.key?(key)
        @pending.delete(key)
      end

      # Keeps the stale entry, held off for a while, and hands it to the waiters.
      def fall_back(promise, key, ttl, stale, source)
        return unless stale && source

        Stale.new(keep(key, stale, ttl), source, key).tap { |fallback| promise.resolve(fallback) }
      end

      def keep(key, entry, ttl) = restore(key, entry.with(retry_at: @clock.call + [HOLD_OFF, ttl * @scale].min))

      def restore(key, entry)
        @entries[key] = entry
        @bytes += entry.weight
        entry
      end

      # Served again from a failed refresh not long ago.
      def held(key, entry, source)
        restore(key, entry)
        served(Stale.new(entry, source, key))
      end

      # The value, or the stale one a failed refresh fell back on, which the call's trace records.
      def served(result)
        return result unless result.is_a?(Stale)

        Trace.stale(result.source, result.entry.stored_at, result.key)
        result.entry.value
      end

      def unwrap(result)
        return [result.value, result.bytes] if result.is_a?(Weighed)

        [result, result.is_a?(String) ? result.bytesize : DEFAULT_WEIGHT]
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, item| [key, item].each { |part| deep_freeze(part) } }
        when Array then value.each { |item| deep_freeze(item) }
        when Data then value.to_h.each_value { |item| deep_freeze(item) }
        end
        value.freeze
      end

      def store(key, value, weight, ttl)
        return unless ttl.positive? && weight <= @max_bytes

        now = @clock.call
        @entries[key] = Entry.new(value:, expires_at: now + ttl, stale_until: now + ttl + [ttl, MAX_STALE].min,
                                  stored_at: @wall_clock.call, weight:, retry_at: 0)
        @bytes += weight
        evict
      end

      # Entries past their grace period first, then the least recently used, until both bounds hold.
      def evict
        return unless @entries.size > @max_entries || @bytes > @max_bytes

        now = @clock.call
        @entries.delete_if { |_, entry| (entry.stale_until <= now).tap { |expired| @bytes -= entry.weight if expired } }
        while @entries.size > @max_entries || @bytes > @max_bytes
          _, entry = @entries.shift
          @bytes -= entry.weight
        end
      end
    end
  end
end
