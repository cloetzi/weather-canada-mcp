# frozen_string_literal: true

require "nokogiri"

module WeatherCanadaMCP
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

    # [{text:, url:}] for each https link, in order.
    def links(html)
      return [] unless html.is_a?(String)

      Nokogiri::HTML5.fragment(html, max_tree_depth: 64).css("a[href]").filter_map do |anchor|
        url = anchor["href"].to_s.strip
        { text: tidy(anchor.text), url: } if url.match?(%r{\Ahttps://[^\s<>"]+\z})
      end
    end

    def tidy(text) = text.tr("\u00a0", " ").gsub(/[ \t]+/, " ").gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n").strip
  end
end
