# frozen_string_literal: true

module WeatherCanadaMCP
  # The MCP tools, one class per file; Tools::Registry lists them in the order tools/list shows them.
  module Tools
    # What tools share: the upstream sources (avalanche is nil unless enabled), a cache for images, the forecast sites and station directories,
    # the gazetteer, the configuration, a clock (Time.now) and the slots that limit concurrent map compositions.
    Context = Data.define(:ogc, :wms, :basemap, :image_cache, :avalanche, :forecast_sites, :stations, :gazetteer, :config, :clock,
                          :compose_slots)

    # An image a tool returns beside its JSON (Tools::Runner sends it as MCP image content).
    Image = Data.define(:data, :mime_type)

    # What a tool call produced: the data, the credits to print (an empty list means the tool class's own), and an image.
    Result = Data.define(:data, :attributions, :image) do
      def initialize(data:, attributions: [], image: nil) = super
    end
  end
end
