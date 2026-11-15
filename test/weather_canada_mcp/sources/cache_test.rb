# frozen_string_literal: true

require_relative "../../test_helper"

class CacheTest < Minitest::Test
  def cache(**)
    @now = 0.0
    WeatherCanadaMcp::Sources::Cache.new(clock: -> { @now }, **)
  end

  def test_caches_until_the_ttl_expires
    cache = cache()
    calls = 0
    2.times { cache.fetch("k", ttl: 10) { calls += 1 } }
    @now = 11
    cache.fetch("k", ttl: 10) { calls += 1 }

    assert_equal 2, calls
  end

  def test_scale_multiplies_ttls_and_zero_disables_caching
    scaled = cache(scale: 2.0)
    scaled.fetch("k", ttl: 10) { :first }
    @now = 15

    assert_equal :first, scaled.fetch("k", ttl: 10) { :second }

    disabled = cache(scale: 0.0)
    disabled.fetch("k", ttl: 10) { :first }

    assert_equal :second, disabled.fetch("k", ttl: 10) { :second }
  end

  def test_coalesces_concurrent_misses
    cache = cache()
    calls = 0
    results = Sync do |task|
      Array.new(3) do
        task.async do
          cache.fetch("k", ttl: 10) do
            calls += 1
            sleep 0.01
            :value
          end
        end
      end.map(&:wait)
    end

    assert_equal 1, calls
    assert_equal [:value] * 3, results
  end

  def test_errors_reach_every_waiter_and_are_not_cached
    cache = cache()
    errors = Sync do |task|
      Array.new(2) do
        task.async do
          cache.fetch("k", ttl: 10) do
            sleep 0.01
            raise WeatherCanadaMcp::Sources::Error, "down"
          end
        rescue WeatherCanadaMcp::Sources::Error => e
          e.message
        end
      end.map(&:wait)
    end

    assert_equal %w[down down], errors
    assert_equal :ok, cache.fetch("k", ttl: 10) { :ok }
  end

  def test_waiters_are_released_when_the_loader_is_stopped
    cache = cache()
    outcome = Sync do |task|
      loader = task.async { cache.fetch("k", ttl: 10) { sleep 10 } }
      waiter = task.async do
        cache.fetch("k", ttl: 10) { flunk "coalesced callers do not load" }
      rescue WeatherCanadaMcp::Sources::Error => e
        e.message
      end
      sleep 0.01
      loader.stop
      waiter.wait
    end

    assert_match(/cancelled/, outcome)
  end

  def test_evicts_when_full
    cache = cache(max_entries: 2)
    cache.fetch("a", ttl: 5) { 1 }
    cache.fetch("b", ttl: 50) { 2 }
    cache.fetch("c", ttl: 50) { 3 }

    assert_equal 2, cache.size
    assert_equal 2, cache.fetch("b", ttl: 50) { flunk "evicted the wrong entry" }
  end
end
