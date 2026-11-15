# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Something the tool needs cannot be had right now, such as a gazetteer that cannot be built.
    class Unavailable < Error; end
  end
end
