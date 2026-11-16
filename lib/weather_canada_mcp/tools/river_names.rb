# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # Turns a place that is a river into a test for gauge names. Water Survey gauges are named "BOW RIVER AT BANFF" in English
    # and "OUTAOUAIS (RIVIERE DES) A HULL" in French, and the gazetteer lists a river under both names, so the names of every
    # river record at the same spot are used.
    class RiverNames
      ARTICLE = /(?:DES|DU|DE LA|DE L'|DE|D'|LA|LES|LE|L')\s*/
      FRENCH = /\ARIVIERE (?:#{ARTICLE})?(.+)\z/

      # place is the resolved Gazetteer::Place (or nil); same_spot the gazetteer places around it.
      def initialize(place, same_spot)
        @places = place&.type == "River" ? [place, *same_spot.select { |other| other.type == "River" }] : []
      end

      # A lambda taking a normalized gauge name, or nil when the place is not a river. A gauge on the river starts with the
      # river's name ("BOW RIVER AT BANFF", but not "ELBOW RIVER AT SARCEE BRIDGE").
      def filter
        patterns = @places.flat_map { |place| patterns(self.class.normalize(place.name)) }.uniq
        ->(gauge_name) { patterns.any? { |pattern| gauge_name.start_with?(pattern) } } if patterns.any?
      end

      def self.normalize(text) = text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").upcase.squeeze(" ").strip

      private

      # "RIVIERE DES OUTAOUAIS" => ["OUTAOUAIS (RIVIERE", "RIVIERE DES OUTAOUAIS"]
      def patterns(name)
        core = name[FRENCH, 1]
        core ? ["#{core} (RIVIERE", name] : [name]
      end
    end
  end
end
