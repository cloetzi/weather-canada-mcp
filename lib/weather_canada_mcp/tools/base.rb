# frozen_string_literal: true

require "async"
require "time"

module WeatherCanadaMCP
  module Tools
    # A tool declares its name, title, description and arguments at class level and implements #call(args), which
    # returns a Hash (or a Tools::Result) that Tools::Runner serializes with the attribution. A new instance serves each
    # call, so instance variables are safe to use.
    #
    #   class GetForecast < Base
    #     tool_name "get_forecast"
    #     title "Get the weather forecast"
    #     description <<~TEXT
    #       ...
    #     TEXT
    #     location_arguments
    #     argument :hours, :integer, in: 0..24, default: 12, description: "Hourly forecast entries to include (0 to omit)."
    #     argument :lang, :language
    #
    #     def call(args) = ... args.hours ... args.point ... args.lang
    #   end
    class Base
      include Concurrency

      CANADA_LAT = (41.0..84.0)
      CANADA_LON = (-142.0..-52.0)
      MAX_LOCATION_LENGTH = 120

      # A resolved point, with what it was resolved from.
      Point = Data.define(:lat, :lon, :place) do
        def to_h = place ? { query_match: place.to_h } : { lat:, lon: }
      end

      class << self
        # Each of these reads when called without a value and sets when called with one.
        def tool_name(value = nil) = value ? @tool_name = value : @tool_name
        def title(value = nil) = value ? @title = value : @title
        def description(value = nil) = value ? @description = value.tr("\n", " ").strip : @description

        # The arguments declared on this class, in order.
        def arguments = @arguments ||= []

        def argument(name, type, **) = arguments << Argument.new(name, type, **)

        # location (a place name), lat and lon, and the point they resolve to as `args.point`.
        def location_arguments
          @location_arguments = true
          argument :location, :string, max_length: MAX_LOCATION_LENGTH,
                                       description: "A place in Canada: town, park, lake, peak or river, optionally with a province " \
                                                    "(\"Squamish\", \"Lake Louise, AB\", \"Mont-Tremblant, QC\"). Ignored when lat and lon are given."
          coordinate_arguments
        end

        # lat and lon alone, for a tool that treats them its own way.
        def coordinate_arguments
          argument :lat, :number, bounds: CANADA_LAT, description: "Latitude in decimal degrees."
          argument :lon, :number, bounds: CANADA_LON, description: "Longitude in decimal degrees (negative, west)."
        end

        def location_arguments? = @location_arguments || false

        # The condition for the tool to exist; without one it always does. `setting` names what switches it on.
        def enabled_when(setting, &block)
          @setting = setting
          @condition = block
        end

        def conditional? = !@condition.nil?
        attr_reader :setting

        def enabled?(config) = @condition.nil? || @condition.call(config)

        def input_schema
          { type: "object", properties: arguments.to_h { |argument| [argument.name, argument.schema] }, additionalProperties: false }
        end

        def manifest = { name: tool_name, title:, description:, input_schema: }

        # Credits the data source: on results that name no source of their own, and on upstream errors.
        def attribution = ATTRIBUTION

        # The value object `call` receives: one member per declared argument, and `point` for location arguments.
        def arguments_class
          @arguments_class ||= Data.define(*arguments.map(&:name), *(:point if location_arguments?))
        end

        # Checks raw (string-keyed) arguments and returns arguments_class.
        def parse_arguments(raw, config)
          raise InvalidArguments, "arguments must be an object." unless raw.is_a?(Hash)

          unknown = raw.keys.map(&:to_s) - arguments.map { |argument| argument.name.to_s }
          raise InvalidArguments, "unknown arguments: #{unknown.join(", ")}." if unknown.any?

          values = arguments.to_h { |argument| [argument.name, argument.parse(raw[argument.name.to_s], config)] }
          arguments_class.new(**values, **(location_arguments? ? { point: nil } : {}))
        end
      end

      def initialize(context)
        @context = context
        @attributions = []
        @place_names = false
      end

      # Parses the raw arguments, resolves the point and calls the tool. Returns a Tools::Result.
      def run(raw_arguments)
        args = self.class.parse_arguments(raw_arguments, @context&.config)
        args = args.with(point: resolve_point(args)) if self.class.location_arguments?
        result = call(args)
        result = Result.new(data: result) unless result.is_a?(Result)
        Result.new(data: result.data, attributions: credits(result.attributions), image: result.image)
      end

      def call(_args) = raise NotImplementedError

      private

      # Credits a source for the result. Without any, the tool class's own credit is used.
      def attribute(text) = @attributions << text

      # Records that gazetteer place names went into the result, which NRCan's licence asks to be credited.
      def place_names_used! = @place_names = true

      def credits(declared)
        sources = [*declared, *@attributions]
        sources = [self.class.attribution] if sources.empty?
        @place_names ? [*sources, Places::Gazetteer::ATTRIBUTION] : sources
      end

      def ogc = @context.ogc
      def wms = @context.wms
      def basemap = @context.basemap
      def images = @context.image_cache
      def forecast_sites = @context.forecast_sites
      def config = @context.config

      # lat/lon win over location; one of the two is required.
      def resolve_point(args)
        return coordinates(args.lat, args.lon) unless args.lat.nil? && args.lon.nil?

        raise InvalidArguments, "Give a location name, or lat and lon." if args.location.nil? || args.location.strip.empty?

        place = lookup(args.location)
        place_names_used!
        Point.new(lat: place.lat, lon: place.lon, place:)
      end

      def coordinates(lat, lon)
        raise InvalidArguments, "Give both lat and lon." if lat.nil? || lon.nil?
        raise InvalidArguments, "lat and lon must be numbers." unless lat.is_a?(Numeric) && lon.is_a?(Numeric)
        unless CANADA_LAT.cover?(lat) && CANADA_LON.cover?(lon)
          raise InvalidArguments, "#{lat}, #{lon} is outside Canada; ECCC data covers Canada only (lon is negative, west)."
        end

        Point.new(lat: lat.to_f, lon: lon.to_f, place: nil)
      end

      def lookup(location)
        name, province = Places::Gazetteer.split_province(location)
        place = gazetteer.search(name, province:, limit: 1).first
        return place if place

        raise NotFound, "No place named #{name.inspect}#{" in #{province}" if province} was found. " \
                        "Try find_location with a shorter or different name, or pass lat and lon."
      end

      def gazetteer
        @context.gazetteer.open
      rescue Places::Gazetteer::Unavailable => e
        raise Unavailable, "Place names cannot be looked up right now (#{e.message}). Pass lat and lon instead."
      end

      # A bilingual ECCC field ({"en" => ..., "fr" => ...}) in the requested language.
      def localized(value, lang)
        return value unless value.is_a?(Hash) && (value.key?("en") || value.key?("fr"))

        value[lang] || value["en"]
      end

      def round_km(distance) = distance.round(distance < 10 ? 1 : 0)

      # [[distance_km, feature], ...] for the point features of a collection within radius_km, closest first.
      def nearest_features(collection, point, radius_km:, count:, **params)
        data = ogc.items(collection, bbox: Geo.bbox(point.lat, point.lon, radius_km).join(","), **params)
        Array(data["features"]).filter_map do |feature|
          lon, lat = feature.dig("geometry", "coordinates")
          next unless lat.is_a?(Numeric) && lon.is_a?(Numeric) && feature["properties"].is_a?(Hash)

          distance = Geo.distance_km(point.lat, point.lon, lat, lon)
          [distance, feature] if distance <= radius_km
        end.min_by(count, &:first)
      end

      # A GeoMet WMS value at the point, or nil when the layer has none there or then (outside the model or radar
      # domain, or a time it does not hold).
      def wms_value(layer, point, time: nil, ttl: Sources::ECCC::Wms::TTL)
        wms.feature_info(layer, point.lat, point.lon, time:, ttl:)
      rescue Sources::InvalidResponse
        nil
      end

      # The block's value and no note, or no value and a note saying why when an upstream failure stopped it: for results
      # that are useful without one of their parts.
      def attempt
        [yield, nil]
      rescue Sources::Error => e
        [nil, e.message]
      end

      def time(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end

      def now = @context.clock.call
    end
  end
end
