# frozen_string_literal: true

require_relative "../../test_helper"

class RateLimiterTest < Minitest::Test
  def limiter(rate:, burst: 1)
    @now = 0.0
    @slept = []
    WeatherCanadaMcp::Upstream::RateLimiter.new(rate:, burst:, clock: -> { @now }, sleeper: ->(seconds) { @slept << seconds })
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
    assert_raises(ArgumentError) { WeatherCanadaMcp::Upstream::RateLimiter.new(rate: 0) }
  end
end
