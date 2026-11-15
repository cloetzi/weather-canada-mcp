# frozen_string_literal: true

require_relative "../test_helper"

class LocatorTest < Minitest::Test
  def test_nearest_sites_from_the_real_site_list
    with_fake_eccc do |fake|
      app = application(fake)
      locator = WeatherCanadaMcp::Locator.new(ogc: app.ogc)
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
end
