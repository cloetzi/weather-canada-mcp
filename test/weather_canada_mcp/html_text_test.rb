# frozen_string_literal: true

require_relative "../test_helper"

class HtmlTextTest < Minitest::Test
  def text(html) = WeatherCanadaMcp::HtmlText.call(html)

  def test_removes_tags_and_keeps_the_words
    assert_equal "Watch for wind slabs near ridge crests.", text("<h1>Watch for <strong>wind slabs</strong> near ridge crests.</h1><p></p>")
  end

  def test_blocks_and_breaks_end_lines
    assert_equal "First.\nSecond.\nOne\nTwo\nA\nB", text("<p>First.</p><p>Second.</p><ul><li>One</li><li>Two</li></ul>A<br>B")
  end

  def test_decodes_entities_and_keeps_link_text
    assert_equal "Check the stations on the map & forecasts.",
                 text(%(Check the&nbsp;<a href="https://www.avalanche.ca/map">stations&nbsp;</a>on the map &amp; forecasts.))
  end

  def test_drops_scripts_and_styles
    assert_equal "Text", text("<script>alert(1)</script><style>p{}</style><p>Text</p>")
  end

  def test_plain_text_and_non_strings
    assert_equal "Already plain, 5–15 cm.", text(" Already plain, 5–15 cm. ")
    assert_nil text(nil)
    assert_nil text(42)
  end
end
