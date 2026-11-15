# frozen_string_literal: true

module WeatherCanadaMcp
  module Tools
    # A tool declares name, title, description and input schema as class-level constants and implements #call,
    # which returns a Hash (Tools::Runner serializes it and adds the attribution). Arguments arrive with string keys.
    class Base
      CANADA_LAT = (41.0..84.0)
      CANADA_LON = (-142.0..-52.0)
      MAX_LOCATION_LENGTH = 120

      LOCATION_PROPERTIES = {
        location: {
          type: "string", maxLength: MAX_LOCATION_LENGTH,
          description: "A place in Canada: town, park, lake, peak or river, optionally with a province " \
                       "(\"Squamish\", \"Lake Louise, AB\", \"Mont-Tremblant, QC\"). Ignored when lat and lon are given."
        },
        lat: { type: "number", minimum: CANADA_LAT.min, maximum: CANADA_LAT.max, description: "Latitude in decimal degrees." },
        lon: { type: "number", minimum: CANADA_LON.min, maximum: CANADA_LON.max,
               description: "Longitude in decimal degrees (negative, west)." }
      }.freeze
      LANG_PROPERTY = { lang: { type: "string", enum: Config::LANGS, description: "Language of text fields: en or fr." } }.freeze

      # A resolved point, with what it was resolved from.
      Point = Data.define(:lat, :lon, :place) do
        def to_h = place ? { query_match: place.to_h } : { lat:, lon: }
      end

      class << self
        def tool_name = self::NAME
        def title = self::TITLE
        def description = self::DESCRIPTION
        def input_schema = self::INPUT_SCHEMA
        def manifest = { name: tool_name, title:, description:, input_schema: }
      end

      def initialize(context)
        @context = context
      end

      def call(_arguments) = raise NotImplementedError

      private

      def ogc = @context.ogc
      def locator = @context.locator
      def config = @context.config

      def lang(arguments)
        value = arguments["lang"] || config.lang
        Config::LANGS.include?(value) ? value : raise(InvalidArguments, "lang must be en or fr")
      end

      # lat/lon win over location; one of the two is required.
      def resolve_point(arguments)
        lat = arguments["lat"]
        lon = arguments["lon"]
        return coordinates(lat, lon) unless lat.nil? && lon.nil?

        location = arguments["location"]
        raise InvalidArguments, "Give a location name, or lat and lon." unless location.is_a?(String) && !location.strip.empty?

        place = lookup(location)
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
        raise InvalidArguments, "location is longer than #{MAX_LOCATION_LENGTH} characters." if location.length > MAX_LOCATION_LENGTH

        name, province = Places::Gazetteer.split_province(location)
        place = gazetteer.search(name, province:, limit: 1).first
        return place if place

        raise InvalidArguments, "No place named #{name.inspect}#{" in #{province}" if province} was found. " \
                                "Try find_location with a shorter or different name, or pass lat and lon."
      end

      def gazetteer
        @context.places.get
      rescue Places::Gazetteer::Unavailable => e
        raise InvalidArguments, "Place names cannot be looked up right now (#{e.message}). Pass lat and lon instead."
      end

      # A bilingual ECCC field ({"en" => ..., "fr" => ...}) in the requested language.
      def localized(value, lang)
        return value unless value.is_a?(Hash) && (value.key?("en") || value.key?("fr"))

        value[lang] || value["en"]
      end

      def round_km(distance) = distance.round(distance < 10 ? 1 : 0)
    end
  end
end
