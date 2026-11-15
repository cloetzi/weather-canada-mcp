# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    # What one tool call asked of the upstream services: how many requests it made, how many answers came from the cache,
    # and which answers were stale copies served because a refresh failed. It lives in fiber storage, which the fibers a
    # call starts inherit, so the sources record into it without knowing about tool calls. Outside a call nothing is recorded.
    class Trace
      KEY = :weather_mcp_trace

      # A stale answer: the source's name and when the copy was stored.
      Stale = Data.define(:source, :at)

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
        def stale(source, at) = current&.stale!(source, at)
      end

      def request! = @requests += 1
      def hit! = @cache_hits += 1

      def stale!(source, at)
        @stale << Stale.new(source:, at:) unless @stale.any? { |entry| entry.source == source && entry.at == at }
      end
    end
  end
end
