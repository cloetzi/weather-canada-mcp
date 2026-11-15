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
      include PointResolution

      CANADA_LAT = (41.0..84.0)
      CANADA_LON = (-142.0..-52.0)
      MAX_LOCATION_LENGTH = 120

      # A resolved point, with what it was resolved from.
      # others are the places of the same name that could have been meant (see AMBIGUITY_SHARE).
      Point = Data.define(:lat, :lon, :place, :zone, :others) do
        def initialize(lat:, lon:, place:, zone:, others: []) = super

        def to_h
          location = place ? { query_match: place.to_h } : { lat:, lon: }
          location[:other_matches] = others.map { |other| other.to_h.slice(:name, :type, :province) } if others.any?
          location.merge(timezone: zone)
        end
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
        Result.new(data: localized_times(result.data, args.respond_to?(:point) ? args.point&.zone : nil),
                   attributions: credits(result.attributions), image: result.image)
      end

      def call(_args) = raise NotImplementedError

      private

      # Credits a source for the result. Without any, the tool class's own credit is used.
      def attribute(text) = @attributions << text

      # Records that gazetteer place names went into the result, which NRCan's licence asks to be credited.
      def place_names_used! = @place_names = true

      # Every Time in the data becomes local ISO 8601 with its offset, so tools return Time objects and never format them.
      def localized_times(value, zone)
        case value
        when Time then LocalTime.iso8601(value, zone)
        when Hash then value.transform_values { |item| localized_times(item, zone) }
        when Array then value.map { |item| localized_times(item, zone) }
        else value
        end
      end

      def credits(declared)
        sources = [*declared, *@attributions]
        sources = [self.class.attribution] if sources.empty?
        (@place_names ? [*sources, Places::Gazetteer::ATTRIBUTION] : sources).uniq
      end

      def ogc = @context.ogc
      def wms = @context.wms
      def basemap = @context.basemap
      def images = @context.image_cache
      def forecast_sites = @context.forecast_sites
      def stations = @context.stations
      def config = @context.config

      # A bilingual ECCC field ({"en" => ..., "fr" => ...}) in the requested language.
      def localized(value, lang)
        return value unless value.is_a?(Hash) && (value.key?("en") || value.key?("fr"))

        value[lang] || value["en"]
      end

      def round_km(distance) = distance.round(distance < 10 ? 1 : 0)

      # A GeoMet WMS value at the point, or nil when the layer has none there or then (outside the model or radar
      # domain, or a time it does not hold).
      def wms_value(layer, point, time: nil, ttl: Sources::Wms::TTL)
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
