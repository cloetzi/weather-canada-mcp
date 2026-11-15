# frozen_string_literal: true

require "chunky_png"
require "zlib"

module WeatherCanadaMCP
  module Maps
    # Stacks PNG map layers of one size (an optional opaque base map, then transparent overlays) and rings a point, in
    # pure Ruby (chunky_png). Before a layer is decoded, its header must give the size asked for and its pixel data
    # must inflate to no more than that size can hold, so an upstream cannot make the server decode a huge image.
    module Compositor
      MARKER = ChunkyPNG::Color.rgb(200, 0, 0)
      HALO = ChunkyPNG::Color::WHITE
      # The most bytes a pixel takes in a PNG (RGBA, 16 bits a channel).
      MAX_BYTES_PER_PIXEL = 8

      # png is the composed image; base_error says why the base map was left out, when it was.
      Result = Data.define(:png, :base_error)

      module_function

      # overlays and base are PNG bytes; overlays are drawn in order over the base (or white without one). marker is
      # the [x, y] pixel to ring. A base map that cannot be read is left out; an overlay that cannot be read raises
      # Sources::InvalidResponse.
      def compose(overlays, width:, height:, marker:, base: nil)
        canvas, base_error = base_canvas(base, width, height)
        overlays.each { |png| canvas.compose!(decode(png, width, height), 0, 0) }
        mark(canvas, *marker)
        Result.new(png: canvas.to_blob(:good_compression), base_error:)
      end

      def base_canvas(base, width, height)
        return [ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE), nil] if base.nil?

        [decode(base, width, height), nil]
      rescue Sources::InvalidResponse => e
        [ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE), e.message]
      end

      def decode(png, width, height)
        raise Sources::InvalidResponse, "A map image was not the #{width}x#{height} pixels asked for." unless dimensions(png) == [width, height]
        raise Sources::InvalidResponse, "A map image holds more data than its size allows." unless inflates_within?(png, width, height)

        ChunkyPNG::Image.from_blob(png)
      rescue ChunkyPNG::Exception, Zlib::Error
        raise Sources::InvalidResponse, "A map image could not be read."
      end

      # [width, height] from the IHDR chunk, which a valid PNG has first; nil for anything else.
      def dimensions(png)
        return unless png.is_a?(String) && png.bytesize >= 24 && png.start_with?(Sources::PNG_SIGNATURE) && png.byteslice(12, 4) == "IHDR"

        png.byteslice(16, 8).unpack("NN")
      end

      # Whether the IDAT chunks inflate to no more than the largest image of this size (a filter byte per row plus
      # MAX_BYTES_PER_PIXEL per pixel). Inflates in pieces and stops as soon as the limit is passed.
      def inflates_within?(png, width, height)
        limit = height * (1 + (width * MAX_BYTES_PER_PIXEL))
        total = 0
        inflater = Zlib::Inflate.new
        idat_chunks(png).each do |data|
          inflater.inflate(data) do |piece|
            total += piece.bytesize
            return false if total > limit
          end
        end
        true
      ensure
        inflater&.close
      end

      # The data of each IDAT chunk, in order; stops at IEND or at a chunk that runs past the end.
      def idat_chunks(png)
        chunks = []
        offset = Sources::PNG_SIGNATURE.bytesize
        while offset + 8 <= png.bytesize
          length, type = png.byteslice(offset, 8).unpack("Na4")
          break if type == "IEND" || offset + 12 + length > png.bytesize

          chunks << png.byteslice(offset + 8, length) if type == "IDAT"
          offset += 12 + length
        end
        chunks
      end

      # A red ring with a white halo, readable on both the base map and the radar colours.
      def mark(canvas, column, row)
        [[8, HALO], [7, MARKER], [6, MARKER], [5, HALO]].each { |radius, colour| canvas.circle(column, row, radius, colour) }
      end
    end
  end
end
