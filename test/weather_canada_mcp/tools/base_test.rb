# frozen_string_literal: true

require_relative "../../test_helper"

class BaseTest < Minitest::Test
  class Count < WeatherCanadaMcp::Tools::Base
    def call(arguments) = integer_argument(arguments, "stations", 3, 1..5)
  end

  def count(arguments) = Count.new(nil).call(arguments)

  def test_integer_arguments_default_when_missing_or_null
    assert_equal [3, 3, 5], [count({}), count({ "stations" => nil }), count({ "stations" => 5 })]
  end

  def test_whole_floats_count_as_integers_as_in_json_schema
    assert_equal 2, count({ "stations" => 2.0 })
    assert_instance_of Integer, count({ "stations" => 2.0 })
  end

  def test_integer_arguments_of_another_type_or_out_of_range_are_tool_errors
    ["2", 2.5, 0, 6.0, Float::NAN, Float::INFINITY, true].each do |value|
      error = assert_raises(WeatherCanadaMcp::Tools::InvalidArguments) { count({ "stations" => value }) }

      assert_equal "stations must be a whole number from 1 to 5.", error.message
    end
  end
end
