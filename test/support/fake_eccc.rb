# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/http/server"
require "json"
require "protocol/http/response"
require "socket"
require "uri"
require "zlib"

# Local stand-in for every upstream (api.weather.gc.ca, dd.weather.gc.ca, geo.weather.gc.ca, ftp.maps.canada.ca),
# answering from the captured fixtures in test/fixtures. Records every request; routes can be overridden per test.
class FakeEccc
  Request = Data.define(:path, :query, :headers)

  FIXTURES = File.expand_path("../fixtures", __dir__)
  CGN_PATH = "/pub/nrcan_rncan/vector/geobase_cgn_toponyme/prov_csv_eng/cgn_canada_csv_eng.zip"
  # The points the alert fixtures were captured for (bbox centres in bin/capture-fixtures).
  ALERT_FIXTURES = { [53.54, -113.49] => "api/weather-alerts_edmonton.json", [49.7, -123.15] => "api/weather-alerts_squamish.json" }.freeze

  attr_reader :requests, :url

  def self.fixture(path) = File.read(File.join(FIXTURES, path), encoding: Encoding::UTF_8)

  def self.fixture_json(path) = JSON.parse(fixture(path))

  # A one-member ZIP archive (deflated) of the real CGN sample, shaped like NRCan's download.
  def self.cgn_zip(csv = fixture("cgn/cgn_sample.csv"))
    name = "cgn_canada_csv_eng.csv"
    data = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS).then { |z| z.deflate(csv, Zlib::FINISH).tap { z.close } }
    crc = Zlib.crc32(csv)
    local = [0x04034b50, 20, 0, 8, 0, 0, crc, data.bytesize, csv.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv") + name
    central = [0x02014b50, 20, 20, 0, 8, 0, 0, crc, data.bytesize, csv.bytesize, name.bytesize, 0, 0, 0, 0, 0, 0]
              .pack("VvvvvvvVVVvvvvvVV") + name
    eocd = [0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize + data.bytesize, 0].pack("VvvvvVVv")
    (local + data + central + eocd).b
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
    case request.path
    when "/collections/citypageweather-realtime/items" then "api/citypage_sites.json"
    when %r{\A/collections/citypageweather-realtime/items/([\w-]+)\z}
      "api/citypage_#{Regexp.last_match(1)}.json" if File.exist?(File.join(FIXTURES, "api/citypage_#{Regexp.last_match(1)}.json"))
    when "/collections/weather-alerts/items" then alerts_fixture(request.query["bbox"])
    when CGN_PATH then :cgn
    end
  end

  # The fixture captured for the point inside the bbox; an empty collection anywhere else.
  def alerts_fixture(bbox)
    min_lon, min_lat, max_lon, max_lat = bbox.to_s.split(",").map(&:to_f)
    ALERT_FIXTURES.find { |(lat, lon), _| lat.between?(min_lat, max_lat) && lon.between?(min_lon, max_lon) }&.last || "api/weather-alerts_ottawa.json"
  end
end
