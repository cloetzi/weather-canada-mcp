# frozen_string_literal: true

require "sqlite3"
require "tmpdir"

module WeatherCanadaMcp
  module Places
    # Offline place-name lookup over NRCan's Canadian Geographical Names, loaded into SQLite by Gazetteer::Builder.
    # Read-only once built. Search matches whole names first, then word prefixes (FTS5, diacritics ignored), and ranks
    # by feature type and NRCan's relevance-at-scale; nearest finds the closest named features to a point.
    class Gazetteer
      class Unavailable < WeatherCanadaMcp::Error; end

      SCHEMA_VERSION = 1
      ATTRIBUTION = "Place names: Canadian Geographical Names, Natural Resources Canada (Open Government Licence - Canada)."

      Place = Data.define(:name, :type, :category, :province, :lat, :lon, :score) do
        def to_h = { name:, type:, province:, lat:, lon: }
      end

      PROVINCES = {
        "AB" => "Alberta", "BC" => "British Columbia", "MB" => "Manitoba", "NB" => "New Brunswick",
        "NL" => "Newfoundland and Labrador", "NS" => "Nova Scotia", "NT" => "Northwest Territories", "NU" => "Nunavut",
        "ON" => "Ontario", "PE" => "Prince Edward Island", "QC" => "Quebec", "SK" => "Saskatchewan", "YT" => "Yukon"
      }.freeze
      PROVINCE_ALIASES = PROVINCES.merge("PEI" => "Prince Edward Island", "QUEBEC" => "Quebec", "QUÉBEC" => "Quebec",
                                         "NFLD" => "Newfoundland and Labrador", "YK" => "Yukon", "NWT" => "Northwest Territories")
                                  .merge(PROVINCES.values.to_h { |name| [name.upcase, name] }).freeze

      # The directory the gem builds the database in when WEATHER_MCP_GAZETTEER_PATH is unset.
      def self.default_path(env = ENV)
        base = env["XDG_CACHE_HOME"].to_s
        base = File.join(Dir.home, ".cache") if base.empty?
        File.join(base, "weather-canada-mcp", "gazetteer-v#{SCHEMA_VERSION}.sqlite3")
      rescue ArgumentError # no home directory
        File.join(Dir.tmpdir, "weather-canada-mcp", "gazetteer-v#{SCHEMA_VERSION}.sqlite3")
      end

      # Lowercase, without diacritics or punctuation, single-spaced: the key exact matches compare.
      def self.normalize(text)
        text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^\p{L}\p{N}]+/, " ").strip
      end

      # "Lake Louise, AB" => ["Lake Louise", "Alberta"]; a trailing part that is not a province stays in the name.
      def self.split_province(query)
        name, _, tail = query.to_s.rpartition(",")
        province = PROVINCE_ALIASES[tail.strip.upcase] unless name.empty?
        province ? [name.strip, province] : [query.to_s.strip, nil]
      end

      def self.province_name(value) = value && PROVINCE_ALIASES[value.to_s.strip.upcase]

      def initialize(path)
        raise Unavailable, "the gazetteer database #{path} does not exist" unless File.file?(path)

        @db = SQLite3::Database.new(path, readonly: true)
        @db.results_as_hash = false
        version = @db.get_first_value("SELECT value FROM meta WHERE key = 'schema_version'").to_i
        raise Unavailable, "the gazetteer database #{path} has schema #{version}, expected #{SCHEMA_VERSION}" unless version == SCHEMA_VERSION
      rescue SQLite3::Exception => e
        raise Unavailable, "the gazetteer database #{path} cannot be read (#{e.class})"
      end

      def meta = @db.execute("SELECT key, value FROM meta").to_h

      def size = @db.get_first_value("SELECT count(*) FROM places")

      # Best matches for a place name, best first. province is a code or name ("AB", "Alberta").
      def search(query, province: nil, limit: 5)
        key = self.class.normalize(query)
        return [] if key.empty?

        province = self.class.province_name(province)
        results = rank(rows("SELECT #{COLUMNS} FROM places WHERE key = ?#{" AND province = ?" if province}", [key, province].compact), key)
        results += rank(prefix_matches(key, province, limit * 10) - results, key) if results.size < limit
        results.first(limit)
      end

      # Named features within radius_km, closest first. populated: true keeps cities, towns and other settlements.
      def nearest(lat, lon, radius_km: 25, limit: 5, populated: false)
        min_lon, min_lat, max_lon, max_lat = Geo.bbox(lat, lon, radius_km)
        sql = "SELECT #{COLUMNS} FROM places WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?"
        sql += " AND category = 'Populated Place'" if populated
        rows(sql, [min_lat, max_lat, min_lon, max_lon])
          .map { |place| [Geo.distance_km(lat, lon, place.lat, place.lon), place] }
          .select { |distance, _| distance <= radius_km }
          .sort_by { |distance, place| [distance, -place.score] }
          .first(limit)
      end

      def close = @db.close

      COLUMNS = "name, generic, category, province, lat, lon, weight"
      private_constant :COLUMNS

      private

      def prefix_matches(key, province, limit)
        match = key.split.map { |token| "\"#{token}\"*" }.join(" ")
        sql = "SELECT #{COLUMNS.split(", ").map { |c| "p.#{c}" }.join(", ")} FROM places_fts f JOIN places p ON p.id = f.rowid " \
              "WHERE places_fts MATCH ?#{" AND p.province = ?" if province} ORDER BY p.weight DESC LIMIT ?"
        rows(sql, [match, province, limit].compact)
      end

      def rows(sql, binds) = @db.execute(sql, binds).map { |row| Place.new(*row) }

      # Exact matches outrank prefix matches; among either, a match covering the whole query comes first, then weight.
      def rank(places, key)
        places.sort_by { |place| [self.class.normalize(place.name) == key ? 0 : 1, -place.score] }
      end
    end
  end
end
