# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/http/server"
require "json"
require "protocol/http/response"
require "socket"
require "uri"
require "stringio"
require "zip"

# Local stand-in for every upstream (api.weather.gc.ca, dd.weather.gc.ca, geo.weather.gc.ca, ftp.maps.canada.ca and
# Avalanche Canada's services), answering from the captured fixtures in test/fixtures. Records every request; routes can be overridden per test.
class FakeEccc
  Request = Data.define(:path, :query, :headers)

  FIXTURES = File.expand_path("../fixtures", __dir__)
  CGN_PATH = "/pub/nrcan_rncan/vector/geobase_cgn_toponyme/prov_csv_eng/cgn_canada_csv_eng.zip"
  # The points the alert fixtures were captured for (bbox centres in bin/capture-fixtures).
  ALERT_FIXTURES = { [53.54, -113.49] => "api/weather-alerts_edmonton.json", [49.7, -123.15] => "api/weather-alerts_squamish.json" }.freeze

  attr_reader :requests, :url

  def self.fixture(path) = File.read(File.join(FIXTURES, path), encoding: Encoding::UTF_8)

  def self.fixture_json(path) = JSON.parse(fixture(path))

  # Collections served from one fixture whatever the query (each was captured for one test location).
  FIXED_FIXTURES = {
    "citypageweather-realtime" => "api/citypage_sites.json",
    "swob-stations" => "api/swob-stations_whistler.json",
    "hydrometric-stations" => "api/hydrometric-stations_squamish.json",
    "aqhi-observations-realtime" => "api/aqhi-observations-realtime_kelowna.json"
  }.freeze
  # Collections served per station or location: the query parameter naming it, and fixtures named api/<collection>_<id>.json.
  KEYED_FIXTURES = {
    "swob-realtime" => "msc_id-value", "hydrometric-realtime" => "STATION_NUMBER",
    "hydrometric-monthly-mean" => "STATION_NUMBER", "aqhi-forecasts-realtime" => "location_id"
  }.freeze
  # Avalanche Canada paths => fixture. Forecast points other than Lake Louise get the empty product captured for Toronto.
  AVALANCHE_FIXTURES = [
    [%r{\A/forecasts/(en|fr)/products/point\z}, lambda { |query, lang|
      "avalanche/point_#{lang}_#{query["lat"] == "51.42" ? "lake-louise" : "toronto"}.json"
    }],
    [%r{\A/forecasts/(en|fr)/metadata\z}, ->(_, lang) { "avalanche/metadata_#{lang}.json" }],
    [%r{\A/stations\z}, ->(*) { "avalanche/stations.json" }],
    [%r{\A/stations/(\d+)/measurements\z}, ->(_, id) { "avalanche/measurements_#{id}.json" }],
    [%r{\A/min/submissions\z}, ->(*) { "avalanche/min-submissions_farnham.json" }]
  ].freeze

  # A one-member ZIP archive (deflated) of the real CGN sample, shaped like NRCan's download.
  def self.cgn_zip(csv = fixture("cgn/cgn_sample.csv"))
    Zip::OutputStream.write_buffer(StringIO.new) do |zip|
      zip.put_next_entry("cgn_canada_csv_eng.csv")
      zip.write(csv)
    end.string.b
  end

  def initialize
    @requests = []
    @routes = {}
  end

  # Handler receives a Request and returns [status, headers, body]; it replaces the fixture lookup for that path.
  def route(path, &handler) = @routes[path] = handler

  def start(task = Async::Task.current)
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    @url = "http://127.0.0.1:#{port}"
    server = Async::HTTP::Server.for(Async::HTTP::Endpoint.parse(@url)) { |request| handle(request) }
    @task = task.async { server.run.wait }
    self
  end

  def stop = @task&.stop

  def requests_to(path) = requests.select { |request| request.path == path }

  private

  def handle(request)
    path, query = request.path.split("?", 2)
    params = URI.decode_www_form(query.to_s).to_h
    headers = request.headers.to_h.transform_values { |value| Array(value).join(", ") }
    recorded = Request.new(path:, query: params, headers:)
    @requests << recorded
    request.body&.finish
    status, response_headers, body = (@routes[path] || method(:fixture_response)).call(recorded)
    Protocol::HTTP::Response[status, response_headers.to_a, [body]]
  end

  def fixture_response(request)
    file = fixture_for(request)
    return [404, { "content-type" => "application/json" }, '{"code":"NotFound"}'] unless file
    return [200, { "content-type" => "application/zip" }, self.class.cgn_zip] if file == :cgn

    [200, { "content-type" => "application/geo+json" }, self.class.fixture(file)]
  end

  def fixture_for(request)
    return :cgn if request.path == CGN_PATH
    return avalanche_fixture(request) if AVALANCHE_FIXTURES.any? { |pattern, _| pattern.match?(request.path) }

    collection, item = request.path.match(%r{\A/collections/([\w-]+)/items(?:/([\w-]+))?\z})&.captures
    return keyed_fixture("citypage", item) if collection == "citypageweather-realtime" && item
    return alerts_fixture(request.query["bbox"]) if collection == "weather-alerts"

    FIXED_FIXTURES[collection] || (keyed_fixture(collection, request.query[KEYED_FIXTURES[collection]]) if KEYED_FIXTURES.key?(collection))
  end

  def avalanche_fixture(request)
    AVALANCHE_FIXTURES.each do |pattern, file|
      match = pattern.match(request.path) or next
      path = file.call(request.query, *match.captures)
      return path if File.exist?(File.join(FIXTURES, path))
    end
    nil
  end

  # The fixture captured for one station, location or site, named after its id.
  def keyed_fixture(prefix, id)
    path = "api/#{prefix}_#{id}.json"
    path if id.to_s.match?(/\A[\w-]+\z/) && File.exist?(File.join(FIXTURES, path))
  end

  # The fixture captured for the point inside the bbox; an empty collection anywhere else.
  def alerts_fixture(bbox)
    min_lon, min_lat, max_lon, max_lat = bbox.to_s.split(",").map(&:to_f)
    ALERT_FIXTURES.find { |(lat, lon), _| lat.between?(min_lat, max_lat) && lon.between?(min_lon, max_lon) }&.last || "api/weather-alerts_ottawa.json"
  end
end
