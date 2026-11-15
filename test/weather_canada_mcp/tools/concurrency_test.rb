# frozen_string_literal: true

require_relative "../../test_helper"

class ConcurrencyTest < Minitest::Test
  include WeatherCanadaMCP::Tools::Concurrency

  def test_results_come_back_in_order
    Sync { assert_equal [6, 2, 4], concurrently([3, 1, 2]) { |n| sleep(n * 0.01) && (n * 2) } }
  end

  def test_a_failure_stops_the_siblings
    finished = false

    Sync do
      assert_raises(RuntimeError) do
        concurrently(%i[slow fail]) do |kind|
          raise "boom" if kind == :fail

          sleep 0.5
          finished = true
        end
      end
    end

    refute finished
  end

  def test_first_found_skips_misses
    Sync { assert_equal [2, 4], first_found([1, 2, 3, 4, 5], 2) { |n| n if n.even? } }
  end
end
