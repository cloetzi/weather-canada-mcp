# frozen_string_literal: true

require "async/promise"

module WeatherCanadaMcp
  module Upstream
    # In-process TTL cache keyed by request URL. Concurrent misses for the same key run the block once: the other
    # callers wait for its result (or its error, which is not cached). Bounded: the entry that expires first is
    # evicted when full.
    class Cache
      Entry = Data.define(:value, :expires_at)

      def initialize(max_entries: 512, scale: 1.0, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @max_entries = max_entries
        @scale = scale
        @clock = clock
        @entries = {}
        @pending = {}
      end

      # ttl is in seconds before scaling; a scale of 0 disables caching (but still coalesces concurrent calls).
      def fetch(key, ttl:, &)
        entry = @entries[key]
        return entry.value if entry && entry.expires_at > @clock.call

        waiter = @pending[key]
        return waiter.wait if waiter

        load(key, ttl, &)
      end

      def size = @entries.size

      def clear = @entries.clear

      private

      def load(key, ttl)
        promise = Async::Promise.new
        @pending[key] = promise
        value = yield
        store(key, value, ttl * @scale)
        promise.resolve(value)
        value
      rescue StandardError => e
        promise.reject(e)
        raise
      ensure
        @pending.delete(key)
      end

      def store(key, value, ttl)
        return unless ttl.positive?

        evict if @entries.size >= @max_entries && !@entries.key?(key)
        @entries[key] = Entry.new(value:, expires_at: @clock.call + ttl)
      end

      def evict
        now = @clock.call
        @entries.delete_if { |_, entry| entry.expires_at <= now }
        return if @entries.size < @max_entries

        @entries.delete(@entries.min_by { |_, entry| entry.expires_at }.first)
      end
    end
  end
end
