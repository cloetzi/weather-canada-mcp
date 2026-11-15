# frozen_string_literal: true

require "chunky_png"

module WeatherCanadaMcp
  module Tools
    # Stacks PNG map layers of one size (an opaque base map, then transparent overlays) and rings a point, in pure Ruby
    # (chunky_png). Each layer's size is read from its header before it is decoded, so an upstream cannot make the
    # server decode a huge image.
    module MapImage
      MARKER = ChunkyPNG::Color.rgb(200, 0, 0)
      HALO = ChunkyPNG::Color::WHITE

      module_function

      # layers are PNG bytes, bottom first. marker is the [x, y] pixel to ring. Returns PNG bytes.
      def compose(layers, width:, height:, marker:)
        canvas = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE)
        layers.each { |png| canvas.compose!(decode(png, width, height), 0, 0) }
        mark(canvas, *marker)
        canvas.to_blob(:good_compression)
      end

      def decode(png, width, height)
        raise Sources::InvalidResponse, "A map image was not the #{width}x#{height} pixels asked for." unless dimensions(png) == [width, height]

        ChunkyPNG::Image.from_blob(png)
      rescue ChunkyPNG::Exception, Zlib::Error
        raise Sources::InvalidResponse, "A map image could not be read."
      end

      # [width, height] from the IHDR chunk, which a valid PNG has first; nil for anything else.
      def dimensions(png)
        return unless png.is_a?(String) && png.bytesize >= 24 && png.start_with?(Sources::PNG_SIGNATURE) && png.byteslice(12, 4) == "IHDR"

        png.byteslice(16, 8).unpack("NN")
      end

      # A red ring with a white halo, readable on both the base map and the radar colours.
      def mark(canvas, column, row)
        [[8, HALO], [7, MARKER], [6, MARKER], [5, HALO]].each { |radius, colour| canvas.circle(column, row, radius, colour) }
      end
    end
  end
end
