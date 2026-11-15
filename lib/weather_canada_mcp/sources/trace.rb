# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    # What one tool call asked of the upstream services: how many requests it made, how many answers came from the cache,
    # and which answers were stale copies served because a refresh failed. It lives in fiber storage, which the fibers a
    # call starts inherit, so the sources record into it without knowing about tool calls. Outside a call nothing is recorded.
    class Trace
      KEY = :weather_mcp_trace

      # A stale answer: the source's name, when the copy was stored and the cache key of the request (an origin and a path
      # with its query, never logged).
      Stale = Data.define(:source, :at, :key)

      attr_reader :requests, :cache_hits, :stale

      def initialize
        @requests = 0
        @cache_hits = 0
        @stale = []
      end

      class << self
        def current = Fiber[KEY]

        # Runs the block with a new trace, which it returns, then restores the previous one.
        def around
          previous = current
          trace = Fiber[KEY] = new
          yield trace
        ensure
          Fiber[KEY] = previous
        end

        def request = current&.request!
        def hit = current&.hit!
        def stale(source, at, key) = current&.stale!(source, at, key)
      end

      def request! = @requests += 1
      def hit! = @cache_hits += 1

      def stale!(source, at, key)
        @stale << Stale.new(source:, at:, key:) unless @stale.any? { |entry| entry.key == key }
      end
    end
  end
end
