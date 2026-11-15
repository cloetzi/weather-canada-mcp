# frozen_string_literal: true

require_relative "../../../test_helper"

class GazetteerStoreTest < Minitest::Test
  def store(fake, path: File.join(Dir.mktmpdir, "g.sqlite3"), auto_build: true)
    @now = 0
    @app = application(fake, WEATHER_MCP_GAZETTEER_PATH: path)
    WeatherCanadaMCP::Places::Gazetteer::Store.new(path:, http: @app.http, logger: null_logger, auto_build:, clock: -> { @now })
  end

  def teardown = @app&.close

  def test_builds_once_from_the_download_on_first_use
    with_fake_eccc do |fake|
      store = store(fake)

      refute_predicate store, :available?
      gazetteers = Array.new(3) { Async { store.open } }.map(&:wait)

      assert_equal 1, fake.requests_to(FakeEccc::CGN_PATH).size
      assert_equal "Squamish", gazetteers.first.search("Squamish").first.name
      assert_predicate store, :available?
    end
  end

  def test_without_auto_build_a_missing_database_is_unavailable
    with_fake_eccc do |fake|
      error = assert_raises(WeatherCanadaMCP::Places::Gazetteer::Unavailable) { store(fake, auto_build: false).open }

      assert_match(/gazetteer update/, error.message)
      assert_empty fake.requests
    end
  end

  def test_a_failed_download_is_reported_and_retried_only_after_a_pause
    with_fake_eccc do |fake|
      fake.route(FakeEccc::CGN_PATH) { [404, {}, "gone"] }
      store = store(fake)

      assert_raises(WeatherCanadaMCP::Places::Gazetteer::Unavailable) { store.open }
      fake.route(FakeEccc::CGN_PATH) { [200, {}, FakeEccc.cgn_zip] }
      error = assert_raises(WeatherCanadaMCP::Places::Gazetteer::Unavailable) { store.open }

      assert_match(/not retried/, error.message)
      assert_equal 1, fake.requests_to(FakeEccc::CGN_PATH).size
      @now = WeatherCanadaMCP::Places::Gazetteer::Store::RETRY_AFTER + 1

      assert_operator store.open.size, :>, 0
    end
  end

  def test_unreadable_data_is_unavailable_not_a_crash
    with_fake_eccc do |fake|
      fake.route(FakeEccc::CGN_PATH) { [200, {}, FakeEccc.cgn_zip("Geographical Name,Latitude\n\"unterminated,1\n")] }
      error = assert_raises(WeatherCanadaMCP::Places::Gazetteer::Unavailable) { store(fake).open }

      assert_match(/could not be built/, error.message)
    end
  end

  # The archives below are the real sample with one header field changed, so the CSV streams as far as the lie allows.
  def test_a_csv_shorter_than_declared_is_rejected_after_streaming_and_leaves_no_database
    assert_rejected(declare(size: FakeEccc.fixture("cgn/cgn_sample.csv").bytesize + 1), /shorter than its archive declares/)
  end

  def test_a_csv_longer_than_declared_is_rejected_while_streaming
    assert_rejected(declare(size: 100), /longer than its archive declares/)
  end

  def test_a_csv_that_fails_its_checksum_is_rejected_and_leaves_no_database
    assert_rejected(declare(crc: 0), /checksum/)
  end

  def test_a_csv_declared_over_the_size_cap_is_rejected_before_inflating
    assert_rejected(declare(size: WeatherCanadaMCP::Places::Gazetteer::Store::MAX_CSV_BYTES + 1), /larger than/)
  end

  def test_an_archive_without_a_csv_is_rejected
    archive = Zip::OutputStream.write_buffer(StringIO.new) { |zip| zip.put_next_entry("readme.txt") && zip.write("hi") }.string

    assert_rejected(archive, /no CSV file/)
  end

  def test_corrupt_archives_are_rejected
    with_fake_eccc do |fake|
      fake.route(FakeEccc::CGN_PATH) { [200, {}, "PK not really a zip"] }

      assert_raises(WeatherCanadaMCP::Places::Gazetteer::Unavailable) { store(fake).open }
    end
  end

  private

  def assert_rejected(archive, message)
    with_fake_eccc do |fake|
      fake.route(FakeEccc::CGN_PATH) { [200, {}, archive] }
      store = store(fake)
      error = assert_raises(WeatherCanadaMCP::Places::Gazetteer::Unavailable) { store.open }

      assert_match(message, error.message)
      assert_empty Dir.children(File.dirname(store.path)), "no database, staging or temporary file is left"
    end
  end

  # Rewrites the uncompressed size or CRC in both the local header and the central directory.
  def declare(size: nil, crc: nil)
    archive = FakeEccc.cgn_zip.dup
    central = archive.index("PK\x01\x02".b)
    { 14 => crc, 22 => size }.each { |offset, value| archive[offset, 4] = [value].pack("V") if value }
    { 16 => crc, 24 => size }.each { |offset, value| archive[central + offset, 4] = [value].pack("V") if value }
    archive
  end
end
