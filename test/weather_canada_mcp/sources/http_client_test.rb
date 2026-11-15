# frozen_string_literal: true

require_relative "../../test_helper"
require "zlib"

class HttpClientTest < Minitest::Test
  def limiters = WeatherCanadaMCP::Sources::RateLimiters.new(rate: 100, burst: 10, providers: { api: :a, prefixed: :a })

  def client(fake, **)
    @client = WeatherCanadaMCP::Sources::HttpClient.new(
      origins: { api: fake.url, prefixed: "#{fake.url}/base" }, user_agent: "weather-canada-mcp/test (+contact)", timeout: 5,
      max_concurrency: 2, max_body_bytes: 1000, rate_limiters: limiters,
      base_delay: 0.001, logger: null_logger, **
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
      assert_raises(WeatherCanadaMCP::Sources::ResponseTooLarge) { client.get(:api, "/bomb") }
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

  def test_retry_logs_hide_queries_and_item_ids
    with_fake_eccc do |fake|
      io = StringIO.new
      calls = 0
      fake.route("/collections/c/items/bc-50") { (calls += 1) < 2 ? [503, {}, ""] : [200, {}, "ok"] }
      client(fake, logger: WeatherCanadaMCP::Logger.new(io:)).get(:api, "/collections/c/items/bc-50?bbox=1,2,3,4")

      assert_includes io.string, "path=/collections/c/items/{id}"
      refute_includes io.string, "bc-50"
      refute_includes io.string, "bbox"
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
      client = WeatherCanadaMCP::Sources::HttpClient.new(
        origins: { api: "http://127.0.0.1:#{port}" }, user_agent: "t", timeout: 2, max_concurrency: 1, max_body_bytes: 100,
        rate_limiters: limiters, logger: null_logger, base_delay: 0.001
      )
      error = assert_raises(WeatherCanadaMCP::Sources::TransportError) { client.get(:api, "/x") }

      assert_match(/Could not reach 127\.0\.0\.1/, error.message)
    ensure
      client&.close
    end
  end

  def test_an_origin_names_its_key_url_and_host
    with_fake_eccc do |fake|
      origin = client(fake).origin(:prefixed)

      assert_equal [:prefixed, "#{fake.url}/base", "127.0.0.1"], [origin.key, origin.url, origin.label]
      assert_raises(ArgumentError) { client(fake).origin(:elsewhere) }
    end
  end
end
