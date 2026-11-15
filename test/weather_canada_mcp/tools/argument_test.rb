# frozen_string_literal: true

require_relative "../../test_helper"

class ArgumentTest < Minitest::Test
  Argument = WeatherCanadaMCP::Tools::Argument
  InvalidArguments = WeatherCanadaMCP::Tools::InvalidArguments

  def test_schema_follows_the_declaration
    hours = Argument.new(:hours, :integer, in: 0..24, default: 12, description: "Hours.")

    assert_equal({ type: "integer", minimum: 0, maximum: 24, default: 12, description: "Hours." }, hours.schema)
    assert_equal({ type: "integer", enum: [12, 24], description: "Pick." }, Argument.new(:h, :integer, in: [12, 24], description: "Pick.").schema)
    assert_equal({ type: "string", maxLength: 5, description: "Text." }, Argument.new(:t, :string, max_length: 5, description: "Text.").schema)
    assert_equal %w[en fr], Argument.new(:lang, :language).schema[:enum]
  end

  def test_missing_values_take_the_default
    assert_equal 12, Argument.new(:hours, :integer, in: 0..24, default: 12).parse(nil, nil)
    assert_nil Argument.new(:river, :string).parse(nil, nil)
    assert_equal "fr", Argument.new(:lang, :language).parse(nil, Struct.new(:lang).new("fr"))
  end

  def test_integers_are_checked_and_whole_floats_pass
    hours = Argument.new(:hours, :integer, in: 0..24)

    assert_equal 2, hours.parse(2.0, nil)
    ["2", 2.5, 25, -1, Float::NAN, true].each { |value| assert_raises(InvalidArguments) { hours.parse(value, nil) } }
    assert_raises(InvalidArguments) { Argument.new(:h, :integer, in: [12, 24]).parse(13, nil) }
  end

  def test_strings_numbers_and_languages_are_checked
    assert_raises(InvalidArguments) { Argument.new(:t, :string, max_length: 3).parse("abcd", nil) }
    assert_raises(InvalidArguments) { Argument.new(:t, :string).parse(1, nil) }
    assert_raises(InvalidArguments) { Argument.new(:p, :string, in: %w[rain snow]).parse("hail", nil) }
    assert_raises(InvalidArguments) { Argument.new(:n, :number).parse(Float::INFINITY, nil) }
    assert_raises(InvalidArguments) { Argument.new(:lang, :language).parse("de", nil) }
    assert_in_delta(1.5, Argument.new(:n, :number, bounds: 0.0..1.0).parse(1.5, nil), 0.001, "bounds are for the schema only")
  end

  def test_unknown_arguments_are_refused
    tool = Class.new(WeatherCanadaMCP::Tools::Base) { argument :a, :integer, in: 1..2 }

    assert_raises(InvalidArguments) { tool.parse_arguments({ "b" => 1 }, nil) }
    assert_equal 2, tool.parse_arguments({ "a" => 2 }, nil).a
  end
end
