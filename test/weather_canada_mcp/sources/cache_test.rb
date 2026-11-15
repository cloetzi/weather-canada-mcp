# frozen_string_literal: true

require_relative "../../test_helper"

class CacheTest < Minitest::Test
  Weighed = WeatherCanadaMCP::Sources::Cache::Weighed

  def cache(**)
    @now = 0.0
    WeatherCanadaMCP::Sources::Cache.new(clock: -> { @now }, **)
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
            raise WeatherCanadaMCP::Sources::Error, "down"
          end
        rescue WeatherCanadaMCP::Sources::Error => e
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
      rescue WeatherCanadaMCP::Sources::Error => e
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

  def test_evicts_the_least_recently_used_entry
    cache = cache(max_entries: 3)
    %w[a b c].each { |key| cache.fetch(key, ttl: 100) { key } }

    cache.fetch("a", ttl: 100) { flunk "a is cached" }
    cache.fetch("d", ttl: 100) { "d" }

    assert_equal "new b", cache.fetch("b", ttl: 100) { "new b" }
    assert_equal "a", cache.fetch("a", ttl: 100) { flunk "a was used last, so it stays" }
  end

  def test_expired_entries_go_before_recently_unused_ones
    cache = cache(max_entries: 2)
    cache.fetch("old", ttl: 5) { 1 }
    cache.fetch("long", ttl: 100) { 2 }
    @now = 6
    cache.fetch("new", ttl: 100) { 3 }

    assert_equal 2, cache.fetch("long", ttl: 100) { flunk "long stays" }
  end

  def test_a_byte_budget_bounds_the_entries_by_their_weight
    cache = cache(max_bytes: 100)
    cache.fetch("a", ttl: 100) { Weighed.new(1, 60) }
    cache.fetch("b", ttl: 100) { Weighed.new(2, 60) }

    assert_equal 60, cache.bytes
    assert_equal 1, cache.size
    assert_equal 3, cache.fetch("a", ttl: 100) { Weighed.new(3, 60) }, "a was evicted to make room for b"
    cache.fetch("huge", ttl: 100) { Weighed.new(4, 101) }

    assert_equal 60, cache.bytes, "an entry over the whole budget is not kept"
  end

  def test_strings_weigh_their_size_and_expired_entries_free_their_weight
    cache = cache(max_bytes: 1000)
    cache.fetch("a", ttl: 5) { "x" * 300 }

    assert_equal 300, cache.bytes
    @now = 6
    cache.fetch("a", ttl: 5) { "y" * 10 }

    assert_equal 10, cache.bytes
  end

  def test_stored_values_are_frozen
    cache = cache()
    value = cache.fetch("k", ttl: 10) { { "list" => [{ "name" => +"x" }] } }

    assert_predicate value, :frozen?
    assert_predicate value.dig("list", 0), :frozen?
    assert_predicate value.dig("list", 0, "name"), :frozen?
  end

  def test_a_used_entry_survives_pressure_from_long_lived_ones
    cache = cache(max_entries: 10)
    forecast = -> { cache.fetch("forecast", ttl: 600) { "forecast" } }
    forecast.call
    50.times do |index|
      cache.fetch("list-#{index}", ttl: 86_400) { index }
      @now += 1
      forecast.call if (index % 5).zero?
    end

    assert_equal "forecast", cache.fetch("forecast", ttl: 600) { flunk "the forecast was evicted" }
  end

  def test_callers_waiting_on_a_loader_that_was_stopped_are_told_to_retry
    cache = cache()
    stopped = Class.new(StandardError)
    results = Sync do |task|
      loader = task.async do
        cache.fetch("k", ttl: 10) do
          sleep 0.05
          raise stopped, "its own deadline"
        end
      rescue stopped
        :stopped
      end
      waiter = task.async do
        cache.fetch("k", ttl: 10) { flunk "joined the loader" }
      rescue WeatherCanadaMCP::Sources::Error => e
        e.message
      end
      [loader.wait, waiter.wait]
    end

    assert_equal [:stopped, "The request was cancelled; retry it."], results
  end
end
