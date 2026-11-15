# frozen_string_literal: true

require_relative "../test_helper"

# Stale answers when a refresh fails, and what the debug log and the tool_call lines say about upstream requests.
class ReliabilityTest < Minitest::Test
  SCALE = "0.002" # the alert list's 300 seconds become 0.6: it expires after 0.6 s and is kept for 0.6 s more
  ALERTS = "/collections/weather-alerts/items"
  SWOB = "/collections/swob-realtime/items"
  WHISTLER = { lat: 50.12, lon: -122.96 }.freeze

  def teardown = @app&.close

  def stale_after_failure(path, tool, wait: 0.8, **arguments)
    with_fake_eccc do |fake|
      @app = application(fake, clock: -> { STATIONS_CAPTURED_AT }, WEATHER_MCP_CACHE_SCALE: SCALE)
      first = call_tool(@app, tool, **arguments)
      sleep wait
      fake.route(path) { [500, {}, "broken"] }
      [first, call_tool(@app, tool, **arguments)]
    end
  end

  def test_a_failed_refresh_serves_the_stale_data_and_says_so
    first, second = stale_after_failure(SWOB, "get_current_observations", **WHISTLER)
    (data, error), (again, again_error) = first, second

    refute error
    refute again_error
    assert_match(/\A127\.0\.0\.1 could not be reached; this is the data from 2026-11-15T10:45:00-08:00\.\z/, again["note"])
    assert_equal data["stations"], again["stations"]
    assert_equal "note", again.keys.first
  end

  def test_a_stale_alert_list_says_so_prominently_and_points_to_the_official_page
    _, (alerts, error) = stale_after_failure(ALERTS, "get_alerts", lat: 53.54, lon: -113.49)

    refute error
    assert_match(%r{\AALERTS COULD NOT BE REFRESHED: .* from 2026-11-15T\S+ and may be out of date.* https://weather\.gc\.ca/warnings/index_e\.html},
                 alerts["note"])
    assert_equal 1, alerts["alerts"].size
  end

  def test_the_french_alert_note_points_to_the_french_page
    _, (alerts,) = stale_after_failure(ALERTS, "get_alerts", lat: 53.54, lon: -113.49, lang: "fr")

    assert_includes alerts["note"], "https://meteo.gc.ca/warnings/index_f.html"
  end

  def test_data_past_its_grace_period_is_not_served
    _, (message, error) = stale_after_failure(ALERTS, "get_alerts", wait: 1.5, lat: 53.54, lon: -113.49)

    assert error
    assert_match(/status 500|500/, message)
  end

  def test_a_fresh_result_has_no_note
    with_fake_eccc do |fake|
      @app = application(fake, WEATHER_MCP_CACHE_SCALE: SCALE)
      result, = call_tool(@app, "get_alerts", lat: 53.54, lon: -113.49)

      refute result.key?("note")
    end
  end

  def test_the_trace_follows_the_fibers_a_call_starts
    Sync do
      WeatherCanadaMCP::Sources::Trace.around do |trace|
        Async { WeatherCanadaMCP::Sources::Trace.request }.wait
        Async { Async { WeatherCanadaMCP::Sources::Trace.hit }.wait }.wait

        assert_equal [1, 1], [trace.requests, trace.cache_hits]
      end
    end

    assert_nil WeatherCanadaMCP::Sources::Trace.current
  end

  def test_debug_lines_name_the_resource_and_never_the_query_or_the_place
    io = StringIO.new
    with_fake_eccc do |fake|
      @app = application(fake, logger: WeatherCanadaMCP::Logger.new(io:, level: "debug", format: "json"), clock: -> { STATIONS_CAPTURED_AT })
      2.times { call_tool(@app, "get_current_observations", **WHISTLER) }
    end
    lines = io.string.lines.map { |line| JSON.parse(line) }
    requests = lines.select { |line| line["msg"] == "upstream_request" }
    calls = lines.select { |line| line["msg"] == "tool_call" }

    fields = requests.reject { |line| line["cache_hit"] }.first.keys - %w[time level msg]

    assert_equal %w[cache_hit duration_ms limiter_wait_ms origin resource status], fields.sort
    assert_includes requests.map { |line| line["resource"] }, "/collections/swob-realtime/items"
    assert(requests.any? { |line| line["cache_hit"] })
    assert_operator calls.first["upstream_requests"], :>, 0
    assert_equal 0, calls.last["upstream_requests"]
    assert_operator calls.last["cache_hits"], :>, 0
    refute_match(/50\.12|122\.96|\?|bbox|msc_id|\d{7}/, requests.map { |line| line["resource"] }.join(" "))
    refute_match(/50\.12|122\.96/, io.string)
  end

  def test_the_resource_of_a_wms_request_is_its_layer
    resource = WeatherCanadaMCP::Sources::RequestLog.resource("/geomet?SERVICE=WMS&LAYERS=RADAR_1KM_RRAI&BBOX=49,-123,50,-122&WIDTH=3")

    assert_equal "/geomet RADAR_1KM_RRAI", resource
    assert_equal "/collections/swob-realtime/items/{id}", WeatherCanadaMCP::Sources::RequestLog.resource("/collections/swob-realtime/items/1234?f=json")
  end

  # Limiters whose clock stands still and whose sleeps are instant: the waits the limiter hands out grow as if real.
  def instant_limiters = WeatherCanadaMCP::Sources::RateLimiters.new(rate: 1, clock: -> { 0.0 }, sleeper: ->(_) {})

  def test_simultaneous_cold_calls_queue_for_the_rate_limit_instead_of_being_refused
    results = nil
    with_fake_eccc do |fake|
      @app = WeatherCanadaMCP::Application.new(WeatherCanadaMCP::Config.from_env(env(fake)), logger: null_logger,
                                                                                             clock: lambda {
                                                                                               GEOMET_CAPTURED_AT
                                                                                             }, rate_limiters: instant_limiters)
      points = [50.11, 50.12, 50.13].map { |lat| { lat:, lon: -122.96 } }
      results = points.map { |point| Async { call_tool(@app, "get_snow_outlook", **point) } }.map(&:wait)
      # 36 snow requests and a few more queue behind a burst of 12: over 20 seconds of waiting.
      assert_operator fake.requests.size, :>, 33
    end

    assert_equal [false] * 3, results.map(&:last), results.map(&:first).inspect
  end

  def test_a_wait_longer_than_the_time_left_to_the_deadline_is_still_refused
    limiter = WeatherCanadaMCP::Sources::RateLimiter.new(rate: 1, clock: -> { 0.0 }, sleeper: ->(_) {})
    43.times { limiter.acquire(max_wait: 100) }
    budget = WeatherCanadaMCP::Sources::Trace.around(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45) do
      WeatherCanadaMCP::Sources::Trace.wait_budget
    end

    assert_in_delta 40, budget, 2
    assert_raises(WeatherCanadaMCP::Sources::Busy) { limiter.acquire(max_wait: budget) }
    assert_nil WeatherCanadaMCP::Sources::Trace.wait_budget
  end
end
