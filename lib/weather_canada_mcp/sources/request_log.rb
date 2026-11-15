# frozen_string_literal: true

module WeatherCanadaMCP
  module Sources
    # What the logs may say about a request: the collection or layer, never the query (a bbox, a point), an item or a
    # station id, each of which reveals a location.
    module RequestLog
      LAYERS = /(?:\A|&)LAYERS=([\w.-]{1,100})/

      module_function

      def path_only(path) = path.split("?", 2).first.sub(%r{/items/.*\z}, "/items/{id}").sub(%r{/stations/[^/]+}, "/stations/{id}")

      # The path, and the layer of a WMS request.
      def resource(path)
        base = path_only(path)
        layer = path.split("?", 2)[1].to_s[LAYERS, 1]
        layer ? "#{base} #{layer}" : base
      end
    end
  end
end
