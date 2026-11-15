# frozen_string_literal: true

require "async"
require "async/barrier"

module WeatherCanadaMCP
  module Tools
    # Fiber helpers for tools that fan out upstream requests (the rate limiter still spaces the requests).
    module Concurrency
      # Runs the block for each item in its own fiber and returns the results in order. When one fails, its siblings are
      # stopped and the error is raised.
      def concurrently(items, &block)
        barrier = Async::Barrier.new
        tasks = items.map { |item| barrier.async { block.call(item) } }
        barrier.wait
        tasks.map(&:wait)
      ensure
        barrier&.cancel
      end

      # Up to limit non-nil block results, in candidate order: candidates are tried concurrently, as many at a time as
      # results are still missing, so a station that has not reported gives way to the next nearest.
      def first_found(candidates, limit, &)
        candidates = candidates.dup
        found = []
        found.concat(concurrently(candidates.shift(limit - found.size), &).compact) while found.size < limit && candidates.any?
        found
      end
    end
  end
end
