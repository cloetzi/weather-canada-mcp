# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Nothing matched what was asked for, such as a place name the gazetteer does not know.
    class NotFound < Error; end
  end
end
