# frozen_string_literal: true

require_relative "../../test_helper"
require "zlib"

class HttpClientTest < Minitest::Test
  def client(fake, **)
    @client = WeatherCanadaMcp::Upstream::HttpClient.new(
      origins: { api: fake.url, prefixed: "#{fake.url}/base" }, user_agent: "weather-canada-mcp/test (+contact)", timeout: 5,
      max_concurrency: 2, max_body_bytes: 1000, rate_limiter: WeatherCanadaMcp::Upstream::RateLimiter.new(rate: 100, burst: 10),
      logger: null_logger, base_delay: 0.001, **
    )
  end

  def teardown = @client&.close

  def test_sends_user_agent_and_accept
    with_fake_eccc do |fake|
      fake.route("/x") { [200, { "content-type" => "application/json" }, "{}"] }
      response = client(fake).get(:api, "/x?a=1", accept: "application/geo+json")

      assert_equal 200, response.status
      assert_equal "weather-canada-mcp/test (+contact)", fake.requests.last.headers["user-agent"]
      assert_equal "application/geo+json", fake.requests.last.headers["accept"]
      assert_equal({ "a" => "1" }, fake.requests.last.query)
    end
  end

  def test_prefixes_the_origin_path_and_refuses_unknown_origins
    with_fake_eccc do |fake|
      fake.route("/base/x") { [200, {}, "ok"] }
      client = client(fake)

      assert_equal "ok", client.get(:prefixed, "/x").body
      assert_raises(ArgumentError) { client.get(:elsewhere, "/x") }
      assert_raises(ArgumentError) { client.get(:api, "x") }
    end
  end

  def test_decodes_gzip_and_caps_the_decoded_size
    with_fake_eccc do |fake|
      fake.route("/small") { [200, { "content-encoding" => "gzip" }, Zlib.gzip("a" * 500)] }
      fake.route("/bomb") { [200, { "content-encoding" => "gzip" }, Zlib.gzip("a" * 100_000)] }
      client = client(fake)

      assert_equal "a" * 500, client.get(:api, "/small").body
      assert_raises(WeatherCanadaMcp::Upstream::ResponseTooLarge) { client.get(:api, "/bomb") }
      assert_equal 100_000, client.get(:api, "/bomb", max_body_bytes: 200_000).body.bytesize
    end
  end

  def test_retries_transient_statuses
    with_fake_eccc do |fake|
      calls = 0
      fake.route("/flaky") { (calls += 1) < 3 ? [503, {}, "busy"] : [200, {}, "ok"] }

      assert_equal "ok", client(fake).get(:api, "/flaky").body
      assert_equal 3, calls
    end
  end

  def test_gives_up_after_max_retries
    with_fake_eccc do |fake|
      fake.route("/down") { [502, {}, "bad gateway"] }

      assert_equal 502, client(fake, max_retries: 1).get(:api, "/down").status
      assert_equal 2, fake.requests_to("/down").size
    end
  end

  def test_connection_failures_name_the_host_without_details
    Sync do
      port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
      client = WeatherCanadaMcp::Upstream::HttpClient.new(
        origins: { api: "http://127.0.0.1:#{port}" }, user_agent: "t", timeout: 2, max_concurrency: 1, max_body_bytes: 100,
        rate_limiter: WeatherCanadaMcp::Upstream::RateLimiter.new(rate: 100, burst: 10), logger: null_logger, base_delay: 0.001
      )
      error = assert_raises(WeatherCanadaMcp::Upstream::TransportError) { client.get(:api, "/x") }

      assert_match(/Could not reach 127\.0\.0\.1/, error.message)
    ensure
      client&.close
    end
  end
end
