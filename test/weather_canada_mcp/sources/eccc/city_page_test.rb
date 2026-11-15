# frozen_string_literal: true

require_relative "../../../test_helper"

class CityPageTest < Minitest::Test
  CityPage = WeatherCanadaMCP::Sources::ECCC::CityPage

  def properties = FakeEccc.fixture_json("api/citypage_bc-50.json").fetch("properties")

  def forecast(lang: "en", properties: self.properties) = CityPage.parse(properties, lang:)

  def test_current_conditions
    conditions = forecast.conditions

    assert_equal(Time.utc(2026, 11, 15, 16, 0), conditions.observed_at.getutc.then do |time|
      Time.utc(time.year, time.month, time.day, time.hour, time.min)
    end)
    assert_in_delta 11.3, conditions.temperature_c
    assert_equal "Squamish Airport", conditions.station
    assert_nil conditions.wind_chill, "a wind chill at +11 C is stale data"
    assert_kind_of Time, conditions.observed_at
  end

  def test_no_current_conditions_without_a_report
    assert_nil forecast(properties: properties.merge("currentConditions" => {})).conditions
    assert_nil forecast(properties: properties.except("currentConditions")).conditions
  end

  def test_periods_with_temperatures_and_precipitation
    first = forecast.periods.first

    assert_equal "Today", first.name
    assert_equal({ type: "rain", amount_mm: 15 }, first.precipitation)
    assert_equal [:high_c], first.temperatures.keys
    assert_match(/Rain at times heavy/, first.text)
  end

  def test_snowfall_in_centimetres
    changed = properties
    amount = changed.dig("forecastGroup", "forecasts", 0, "precipitation", "accumulation", "amount")
    amount["units"] = { "en" => "cm", "fr" => "cm" }

    assert_equal({ type: "rain", amount_cm: 15 }, forecast(properties: changed).periods.first.precipitation)
  end

  def test_hours_warnings_and_sun
    forecast = forecast()

    assert_equal 24, forecast.hours.size
    assert_kind_of Time, forecast.hours.first.time
    assert_equal "YELLOW WARNING - RAINFALL", forecast.warnings.first.headline
    assert_kind_of Time, forecast.sunrise
    assert_kind_of Time, forecast.sunset
  end

  def test_text_in_the_language_asked_for_with_english_as_the_fallback
    assert_equal "Aujourd'hui", forecast(lang: "fr").periods.first.name
    assert_equal "Today", forecast(lang: "de").periods.first.name
  end

  def test_a_missing_part_leaves_nils_not_errors
    empty = forecast(properties: {})

    assert_nil empty.issued_at
    assert_empty empty.periods
    assert_empty empty.hours
    assert_empty empty.warnings
    assert_nil empty.sunrise
  end

  def test_the_wind_chill_and_humidex_that_apply_are_kept
    changed = properties
    conditions = changed["currentConditions"]
    conditions["temperature"]["value"] = { "en" => -10, "fr" => -10 }
    conditions["windChill"] = { "value" => { "en" => -18, "fr" => -18 } }

    assert_equal(-18, forecast(properties: changed).conditions.wind_chill)
  end
end
