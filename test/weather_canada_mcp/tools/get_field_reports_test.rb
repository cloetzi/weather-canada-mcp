# frozen_string_literal: true

require_relative "../../test_helper"

class GetFieldReportsTest < Minitest::Test
  FARNHAM = { lat: 50.41, lon: -116.5, radius_km: 10, days: 31 }.freeze
  PATH = "/min/submissions"

  def reports(**) = call_with_fake("get_field_reports", clock: -> { AVALANCHE_CAPTURED_AT }, env: AVALANCHE_ENABLED, **)

  def fixture = FakeEccc.fixture_json("avalanche/min-submissions_farnham.json")

  # The fixture as Avalanche Canada serves it, with the submitter fields the capture script strips.
  def with_submitters(data = fixture)
    items = data["items"].map { |item| item.merge("userID" => "auth0|0123456789abcdef", "username" => "skier_example", "anonymous" => false) }
    { PATH => ->(_) { [200, {}, JSON.generate(data.merge("items" => items))] } }
  end

  def test_reports_newest_first
    result, error = reports(**FARNHAM)

    refute error
    assert_equal(["Farnham season opener", "Early Farnham ski trip"], result["reports"].map { |report| report["title"] })
    assert_equal %w[2026-10-16 2026-11-15], result.values_at("from", "to")
  end

  def test_asks_for_the_days_and_area
    _, _, requests = reports(**FARNHAM)

    assert_equal({ "fromdate" => "2026-10-16", "todate" => "2026-11-15", "bbox" => "-116.64096,50.32017,-116.35904,50.49983" },
                 requests.first.query)
  end

  def test_avalanche_observations
    avalanche = reports(**FARNHAM).first.dig("reports", 0, "avalanches", 0)

    assert_equal({ "when" => "yesterday", "date" => "2026-11-12", "size" => "1.5", "problem" => "persistentSlab", "trigger" => "person",
                   "started_by" => ["accidental"], "aspects" => %w[NE N], "elevation" => "alpine", "crown_depth_cm" => 40,
                   "width_m" => 70, "run_length_m" => 40, "start_zone_elevation_m" => 2500, "incline_deg" => 35,
                   "weak_layers" => %w[facets depthHoar], "crust" => false }, avalanche)
  end

  def test_comments_are_passed_through
    report = reports(**FARNHAM).first.dig("reports", 0)

    assert_equal fixture.dig("items", 0, "comments").strip, report["comments"]
    assert_equal "https://avalanche.ca/mountain-information-network/submissions/#{fixture.dig("items", 0, "submissionID")}", report["url"]
  end

  def test_never_includes_who_submitted_a_report
    result, = reports(**FARNHAM, routes: with_submitters)
    json = JSON.generate(result)

    refute_empty result["reports"]
    %w[userID username anonymous auth0 skier_example].each { |text| refute_includes json, text }
  end

  def test_contact_details_in_the_text_are_removed
    data = fixture
    data["items"][0] =
      data["items"][0].merge("comments" => "Lost a ski. Call 403-555-0123 or (604) 555 0199, email a.b@example.com, or DM @farnham_skier.")
    result, = reports(**FARNHAM, routes: with_submitters(data))

    assert_equal "Lost a ski. Call [contact details removed] or [contact details removed], email [contact details removed], " \
                 "or DM [contact details removed].", result.dig("reports", 0, "comments")
  end

  def test_sizes_and_dates_are_not_mistaken_for_contact_details
    tool = WeatherCanadaMcp::Tools::GetFieldReports.new(nil)
    text = "Size 1.5 at 2500 m on 2026-11-12; CTM13 30cm down, 35 degrees."

    assert_equal text, tool.send(:redact, text)
  end

  def test_limit_and_radius
    result, = reports(**FARNHAM, limit: 1)
    nearer, = reports(**FARNHAM, radius_km: 1)

    assert_equal 1, result["reports"].size
    assert_equal 1, result["more_reports"]
    assert_equal(["Farnham season opener"], nearer["reports"].map { |report| report["title"] })
  end

  def test_nothing_found
    result, = reports(**FARNHAM, routes: { PATH => ->(_) { [200, {}, '{"items":[]}'] } })

    assert_empty result["reports"]
    assert_match(/No field report within 10 km/, result["note"])
    assert result["safety_note"].start_with?("Avalanche forecasts are regional")
  end

  def test_attribution_says_reports_are_unverified
    assert_match(/Mountain Information Network of Avalanche Canada .* not verified/, reports(**FARNHAM).first["attribution"])
  end
end
