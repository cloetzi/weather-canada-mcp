# frozen_string_literal: true

require "uri"

module WeatherCanadaMCP
  module Sources
    # An upstream service as configured: its key (:eccc_api), its URL and the host name that error messages use, so a
    # message names the host the request went to even when the URL points at a mirror.
    Origin = Data.define(:key, :url, :label) do
      def self.build(key, url) = new(key:, url:, label: URI(url).host)
    end
  end
end
