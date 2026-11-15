# frozen_string_literal: true

require "nokogiri"

module WeatherCanadaMcp
  # Plain text from an HTML fragment, words unchanged: tags are dropped (link text is kept), entities decoded, block
  # elements and <br> end a line, and whitespace is tidied. Used for upstream text that must be passed through verbatim.
  module HtmlText
    BLOCKS = %w[p div h1 h2 h3 h4 h5 h6 li dt dd tr blockquote pre section article header footer].freeze

    module_function

    def call(html)
      return unless html.is_a?(String)

      fragment = Nokogiri::HTML5.fragment(html, max_tree_depth: 64)
      fragment.css("script, style").each(&:remove)
      fragment.css("br").each { |node| node.replace("\n") }
      fragment.css(BLOCKS.join(", ")).each { |node| node.add_next_sibling("\n") }
      tidy(fragment.text)
    end

    def tidy(text) = text.tr(" ", " ").gsub(/[ \t]+/, " ").gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n").strip
  end
end
