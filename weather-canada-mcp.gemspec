# frozen_string_literal: true

require_relative "lib/weather_canada_mcp/version"

Gem::Specification.new do |spec|
  spec.name = "weather-canada-mcp"
  spec.version = WeatherCanadaMcp::VERSION
  spec.authors = ["cloetzi"]
  spec.summary = "Unofficial MCP server for Environment and Climate Change Canada weather open data"
  spec.description = "Read-only MCP server with outdoor-focused tools (forecasts, alerts, observations, rivers, " \
                     "air quality, snow, radar, marine) built on ECCC's MSC GeoMet and Datamart open data."
  spec.homepage = "https://github.com/cloetzi/weather-canada-mcp"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 4.0"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "bin/weather-canada-mcp", "LICENSE", "NOTICE", "README.md", "CHANGELOG.md"]
  spec.bindir = "bin"
  spec.executables = ["weather-canada-mcp"]

  spec.add_dependency "async-http", "~> 0.105"
  spec.add_dependency "csv", "~> 3.3"
  spec.add_dependency "falcon", "~> 0.57"
  spec.add_dependency "mcp", "~> 1.9"
  spec.add_dependency "nokogiri", "~> 1.18"
  spec.add_dependency "sqlite3", "~> 2.7"
  spec.add_dependency "zeitwerk", "~> 2.8"
end
