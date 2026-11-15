# frozen_string_literal: true

require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect("cli" => "CLI", "ogc_api" => "OgcApi", "http" => "HTTP")
loader.setup

module WeatherCanadaMcp
  # Base of every error this gem raises. The CLI reports one that reaches it as a message, without a backtrace.
  class Error < StandardError; end

  # Required on every tool result by the ECCC Data Servers End-use Licence.
  ATTRIBUTION = "Data Source: Environment and Climate Change Canada. " \
                "Unofficial tool, not affiliated with or endorsed by ECCC."
end
