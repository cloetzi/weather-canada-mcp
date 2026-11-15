# frozen_string_literal: true

require "async/promise"

module WeatherCanadaMCP
  module Sources
    # In-process TTL cache keyed by request URL. Concurrent misses for the same key run the block once: the other
    # callers wait for its result (or its error, which is not cached). Meant for one reactor thread.
    #
    # Bounded twice: by entry count and by a byte budget, where an entry weighs its response body (a block returns a
    # Weighed for that; a String weighs its own size). When over either bound the expired entries go first, then the
    # least recently used. Stored values are frozen, so a caller cannot change what the next one reads.
    class Cache
      Entry = Data.define(:value, :expires_at, :weight)

      # A value and the size of the response it was made from.
      Weighed = Data.define(:value, :bytes)

      DEFAULT_WEIGHT = 1024

      def initialize(max_entries: 512, max_bytes: 64 * 1024 * 1024, scale: 1.0, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @max_entries = max_entries
        @max_bytes = max_bytes
        @scale = scale
        @clock = clock
        @entries = {}
        @bytes = 0
        @pending = {}
      end

      attr_reader :bytes

      # ttl is in seconds before scaling; a scale of 0 disables caching (but still coalesces concurrent calls).
      def fetch(key, ttl:, &)
        entry = @entries.delete(key)
        if entry && entry.expires_at > @clock.call
          @entries[key] = entry # most recently used goes last
          return entry.value
        end
        @bytes -= entry.weight if entry

        waiter = @pending[key]
        return waiter.wait if waiter

        load(key, ttl, &)
      end

      def size = @entries.size

      def clear
        @entries.clear
        @bytes = 0
      end

      private

      def load(key, ttl)
        promise = Async::Promise.new
        @pending[key] = promise
        value, weight = unwrap(yield)
        value = deep_freeze(value)
        store(key, value, weight, ttl * @scale)
        promise.resolve(value)
        value
      rescue StandardError => e
        promise.reject(e)
        raise
      ensure
        # A loader stopped by something other than a StandardError (Async::Stop when its client goes away) must still
        # release the fibers waiting on it.
        promise.reject(Sources::Error.new("The request was cancelled; retry it.")) unless promise.resolved?
        @pending.delete(key)
      end

      def unwrap(result)
        return [result.value, result.bytes] if result.is_a?(Weighed)

        [result, result.is_a?(String) ? result.bytesize : DEFAULT_WEIGHT]
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, item| [key, item].each { |part| deep_freeze(part) } }
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end

      def store(key, value, weight, ttl)
        return unless ttl.positive? && weight <= @max_bytes

        @entries[key] = Entry.new(value:, expires_at: @clock.call + ttl, weight:)
        @bytes += weight
        evict
      end

      # Expired entries first, then the least recently used, until both bounds hold.
      def evict
        return unless @entries.size > @max_entries || @bytes > @max_bytes

        now = @clock.call
        @entries.delete_if { |_, entry| (entry.expires_at <= now).tap { |expired| @bytes -= entry.weight if expired } }
        while @entries.size > @max_entries || @bytes > @max_bytes
          _, entry = @entries.shift
          @bytes -= entry.weight
        end
      end
    end
  end
end
