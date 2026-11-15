# frozen_string_literal: true

require "date"
require "uri"

module WeatherCanadaMCP
  module Sources
    module AvalancheCanada
      # Mountain Information Network (MIN) field reports.
      class FieldReports < Client
        # Seconds, before WEATHER_MCP_CACHE_SCALE.
        TTL = 900
        MAX_SUBMISSION_DAYS = 31

        # MIN submissions observed between two dates (at most 31 days) inside bbox [min_lon, min_lat, max_lon, max_lat].
        def submissions(from:, to:, bbox:)
          raise ArgumentError, "invalid date range" unless from.is_a?(Date) && to.is_a?(Date) && from <= to
          raise ArgumentError, "the date range is longer than #{MAX_SUBMISSION_DAYS} days" if to - from >= MAX_SUBMISSION_DAYS
          raise ArgumentError, "invalid bbox" unless bbox.size == 4 && bbox.all?(Numeric)

          query = URI.encode_www_form(fromdate: from.iso8601, todate: to.iso8601, bbox: bbox.join(","))
          data = get(:avalanche, "/min/submissions?#{query}", TTL, Hash)
          items = data["items"]
          items.is_a?(Array) ? items : raise(InvalidResponse, "#{NAMES[:avalanche]} returned field reports in an unexpected shape.")
        end
      end
    end
  end
end
