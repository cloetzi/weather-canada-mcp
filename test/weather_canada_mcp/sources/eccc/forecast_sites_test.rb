# frozen_string_literal: true

require_relative "../../../test_helper"

class LocatorTest < Minitest::Test
  def test_nearest_sites_from_the_real_site_list
    with_fake_eccc do |fake|
      app = application(fake)
      locator = WeatherCanadaMCP::Sources::ECCC::ForecastSites.new(ogc: app.ogc)
      nearest = locator.nearest_sites(50.06, -122.95, limit: 2)

      assert_equal(%w[bc-86 bc-16], nearest.map { |_, site| site.id })
      assert_equal "Whistler", nearest.first.last.name_in("fr")
      assert_equal 844, locator.sites.size
      locator.nearest_sites(45.4, -75.7)

      assert_equal 1, fake.requests_to("/collections/citypageweather-realtime/items").size, "the site list is cached"
    ensure
      app&.close
    end
  end

  def test_every_site_has_a_known_zone
    zones = WeatherCanadaMCP::Sources::ECCC::ForecastSites::ZONES

    assert_equal 844, zones.size
    assert_empty(zones.values.uniq.reject { |zone| WeatherCanadaMCP::LocalTime.known?(zone) })
  end

  def test_the_zone_of_a_point_is_its_nearest_sites
    with_fake_eccc do |fake|
      app = application(fake)
      sites = WeatherCanadaMCP::Sources::ECCC::ForecastSites.new(ogc: app.ogc)

      assert_equal "America/Vancouver", sites.zone_at(50.12, -122.96)
      assert_equal "America/Edmonton", sites.zone_at(51.42, -116.18)
      assert_equal "America/Toronto", sites.zone_at(43.65, -79.38)
    ensure
      app&.close
    end
  end
end
