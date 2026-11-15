# frozen_string_literal: true

require "json"

module WeatherCanadaMCP
  module Sources
    # A cached GET of one origin that checks the status, parses the JSON and checks its shape: what the ECCC OGC API and
    # Avalanche Canada's services share. The parsed value is cached per path for ttl seconds.
    class JsonClient
      def initialize(http:, cache:, origin:)
        @http = http
        @cache = cache
        @origin_key = origin
      end

      # shape is the class the document must have (Hash or Array). The block, when given, sees each document as it is
      # fetched, not when it comes from the cache.
      def get(path, ttl, shape: Hash, accept: "application/json")
        @cache.fetch("#{@origin_key}:#{path}", ttl:) do
          response = @http.get(@origin_key, path, accept:)
          raise StatusError.new(response.status, origin.label) unless response.success?

          data = parse(response.body, shape)
          yield data if block_given?
          Cache::Weighed.parsed(data, response.body)
        end
      end

      private

      def origin = @http.origin(@origin_key)

      def parse(body, shape)
        data = JSON.parse(body.dup.force_encoding(Encoding::UTF_8), max_nesting: 64)
        raise InvalidResponse, "#{origin.label} returned JSON in an unexpected shape." unless data.is_a?(shape)

        data
      rescue JSON::ParserError
        raise InvalidResponse, "#{origin.label} returned a response that is not valid JSON."
      end
    end
  end
end
