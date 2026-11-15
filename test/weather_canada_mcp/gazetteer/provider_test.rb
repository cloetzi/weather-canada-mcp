# frozen_string_literal: true

require_relative "../../test_helper"

class GazetteerProviderTest < Minitest::Test
  def provider(fake, path: File.join(Dir.mktmpdir, "g.sqlite3"), auto_build: true)
    @app = application(fake, WEATHER_MCP_GAZETTEER_PATH: path)
    WeatherCanadaMcp::Gazetteer::Provider.new(path:, http: @app.http, logger: null_logger, auto_build:)
  end

  def teardown = @app&.close

  def test_builds_once_from_the_download_on_first_use
    with_fake_eccc do |fake|
      provider = provider(fake)

      refute_predicate provider, :available?
      gazetteers = Array.new(3) { Async { provider.get } }.map(&:wait)

      assert_equal 1, fake.requests_to(FakeEccc::CGN_PATH).size
      assert_equal "Squamish", gazetteers.first.search("Squamish").first.name
      assert_predicate provider, :available?
    end
  end

  def test_without_auto_build_a_missing_database_is_unavailable
    with_fake_eccc do |fake|
      error = assert_raises(WeatherCanadaMcp::Gazetteer::Unavailable) { provider(fake, auto_build: false).get }

      assert_match(/gazetteer update/, error.message)
      assert_empty fake.requests
    end
  end

  def test_a_failed_download_is_reported_and_retried_later
    with_fake_eccc do |fake|
      fake.route(FakeEccc::CGN_PATH) { [404, {}, "gone"] }
      provider = provider(fake)

      assert_raises(WeatherCanadaMcp::Gazetteer::Unavailable) { provider.get }
      fake.route(FakeEccc::CGN_PATH) { [200, {}, FakeEccc.cgn_zip] }

      assert_operator provider.get.size, :>, 0
    end
  end

  def test_corrupt_archives_are_rejected
    with_fake_eccc do |fake|
      fake.route(FakeEccc::CGN_PATH) { [200, {}, "PK not really a zip"] }

      assert_raises(WeatherCanadaMcp::Gazetteer::Unavailable) { provider(fake).get }
    end
  end

  def test_zip_entry_enforces_the_size_limit
    archive = FakeEccc.cgn_zip

    assert_raises(WeatherCanadaMcp::Error) do
      WeatherCanadaMcp::Gazetteer::ZipEntry.first(archive, suffix: ".csv", max_bytes: 100) { |_chunk| nil }
    end
    csv = +""
    WeatherCanadaMcp::Gazetteer::ZipEntry.first(archive, suffix: ".csv", max_bytes: 1 << 20) { |chunk| csv << chunk }

    assert_equal FakeEccc.fixture("cgn/cgn_sample.csv").b, csv
  end
end
