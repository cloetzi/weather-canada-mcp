# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Base of what a tool raises to give the model a readable tool error. The runner rescues it and logs the subclass name.
    class Error < WeatherCanadaMCP::Error; end
  end
end
