# frozen_string_literal: true

require_relative "../../test_helper"

# Runs against the database built from test/fixtures/cgn/cgn_sample.csv (real CGN rows).
class GazetteerTest < Minitest::Test
  Gazetteer = WeatherCanadaMCP::Places::Gazetteer

  def setup = @gazetteer = Gazetteer.new(gazetteer_path)

  def teardown = @gazetteer.close

  def test_exact_name_ranks_settlements_first
    best = @gazetteer.search("Squamish").first

    assert_equal ["Squamish", "District Municipality", "British Columbia"], [best.name, best.type, best.province]
  end

  def test_a_city_ranks_before_the_province_of_the_same_name
    ["Québec", "Quebec", "quebec, QC"].each do |query|
      name, province = Gazetteer.split_province(query)
      best = @gazetteer.search(name, province:).first

      assert_equal %w[Québec Town], [best.name, best.type], query
      assert_in_delta 46.81, best.lat, 0.01
    end
    assert_equal "Province", @gazetteer.search("Alberta").first.type, "no settlement of that name: the province"
  end

  def test_common_english_names_find_the_place
    assert_equal(%w[Québec Town], @gazetteer.search("Quebec City").first.then { [it.name, it.type] })
    assert_equal "Québec", @gazetteer.search("Ville de Québec", province: "QC").first.name
    assert_equal "Montréal", @gazetteer.search("Montreal").first.name
    assert_empty @gazetteer.search("Quebec City", province: "ON")
  end

  def test_province_filter_and_suffix
    assert_equal "Alberta", @gazetteer.search("Lake Louise", province: "AB").first.province
    assert_equal "Hamlet", @gazetteer.search("Lake Louise", province: "Alberta").first.type
    assert_equal ["Lake Louise", "Alberta"], Gazetteer.split_province("Lake Louise, AB")
    assert_equal %W[Rivi\u00E8re-du-Loup Quebec], Gazetteer.split_province("Rivière-du-Loup, Québec")
    assert_equal ["Squamish, Howe Sound", nil], Gazetteer.split_province("Squamish, Howe Sound")
  end

  def test_ignores_case_diacritics_and_punctuation
    assert_equal "Rivière-du-Loup", @gazetteer.search("riviere du loup").first.name
    assert_equal "Trois-Rivières", @gazetteer.search("TROIS RIVIERES").first.name
  end

  def test_prefix_matches_when_no_exact_match
    names = @gazetteer.search("Mount Rob").map(&:name)

    assert_includes names, "Mount Robson"
  end

  def test_unknown_or_empty_queries_return_nothing
    assert_empty @gazetteer.search("Nowhereville")
    assert_empty @gazetteer.search("  ")
    assert_empty @gazetteer.search("\"*)(")
  end

  def test_nearest_is_sorted_by_distance
    results = @gazetteer.nearest(49.7, -123.15, radius_km: 50, limit: 3)

    assert_equal "Squamish", results.first.last.name
    assert_equal results.map(&:first).sort, results.map(&:first)
    assert(results.all? { |distance, _| distance <= 50 })
  end

  def test_meta_records_the_build
    assert_equal "1", @gazetteer.meta["schema_version"]
    assert_operator @gazetteer.size, :>, 20
  end

  def test_missing_or_foreign_files_are_unavailable
    assert_raises(Gazetteer::Unavailable) { Gazetteer.new("/nonexistent/gazetteer.sqlite3") }
    assert_raises(Gazetteer::Unavailable) { Gazetteer.new(write_tempfile("x.sqlite3", "not a database")) }
  end

  def test_default_path_follows_xdg
    assert_equal "/cache/weather-canada-mcp/gazetteer-v1.sqlite3", Gazetteer.default_path("XDG_CACHE_HOME" => "/cache")
  end
end
