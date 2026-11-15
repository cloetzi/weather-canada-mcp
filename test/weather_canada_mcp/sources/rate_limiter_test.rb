# frozen_string_literal: true

require_relative "../../test_helper"

class RateLimiterTest < Minitest::Test
  def limiter(rate:, burst: 1)
    @now = 0.0
    @slept = []
    WeatherCanadaMCP::Sources::RateLimiter.new(rate:, burst:, clock: -> { @now }, sleeper: ->(seconds) { @slept << seconds })
  end

  def test_spaces_requests_at_the_rate
    limiter = limiter(rate: 2)
    delays = Array.new(3) { limiter.acquire }

    assert_equal [0.0, 0.5, 1.0], delays
  end

  def test_allows_a_burst_then_spaces_out
    limiter = limiter(rate: 1, burst: 3)
    delays = Array.new(5) { limiter.acquire }

    assert_equal [0.0, 0.0, 0.0, 1.0, 2.0], delays
    assert_equal [1.0, 2.0], @slept
  end

  def test_recovers_after_idle_time
    limiter = limiter(rate: 1)
    2.times { limiter.acquire }
    @now = 10.0

    assert_in_delta 0.0, limiter.acquire
  end

  def test_rejects_a_non_positive_rate
    assert_raises(ArgumentError) { WeatherCanadaMCP::Sources::RateLimiter.new(rate: 0) }
  end

  def test_refuses_a_wait_longer_than_the_most_it_may_take
    limiter = limiter(rate: 1)
    21.times { limiter.acquire(max_wait: 100) }
    error = assert_raises(WeatherCanadaMCP::Sources::Busy) { limiter.acquire }

    assert_match(/Try again/, error.message)
    @now = 21.0

    assert_in_delta 0.0, limiter.acquire, 0.001, "a refused request took no slot"
  end

  def test_a_caller_stopped_while_waiting_gives_its_slot_back
    @now = 0.0
    interrupted = RateLimiterInterrupt.new
    limiter = WeatherCanadaMCP::Sources::RateLimiter.new(rate: 1, clock: -> { @now }, sleeper: ->(_) { raise interrupted })
    limiter.acquire
    assert_raises(RateLimiterInterrupt) { limiter.acquire }
    @now = 1.0

    assert_in_delta 0.0, limiter.acquire, 0.001
  end

  def test_each_provider_has_its_own_limit
    @now = 0.0
    limiters = WeatherCanadaMCP::Sources::RateLimiters.new(rate: 1, burst: 1, clock: -> { @now }, sleeper: ->(_) {})
    limiters.acquire(:eccc_api)

    assert_in_delta 1.0, limiters.acquire(:geomet), 0.001, "ECCC's two services share a limit"
    assert_in_delta 0.0, limiters.acquire(:basemap), 0.001
    assert_in_delta 0.0, limiters.acquire(:avalanche), 0.001
    assert_raises(KeyError) { limiters.acquire(:elsewhere) }
  end

  def test_the_default_burst_is_twelve
    @now = 0.0
    limiters = WeatherCanadaMCP::Sources::RateLimiters.new(rate: 1, clock: -> { @now }, sleeper: ->(_) {})

    assert_equal [0.0] * 12, Array.new(12) { limiters.acquire(:eccc_api) }
    assert_in_delta 1.0, limiters.acquire(:eccc_api), 0.001
  end
end

class RateLimiterInterrupt < StandardError; end
