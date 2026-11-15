# frozen_string_literal: true

require "csv"
require "fileutils"
require "sqlite3"
require "time"

module WeatherCanadaMCP
  module Places
    class Gazetteer
      # Loads the CGN CSV (one row per name) into a new SQLite database, written to a temporary file and renamed into
      # place, so readers never see a half-built database.
      class Builder
        # Prominence by NRCan concise code; unlisted codes get DEFAULT_WEIGHT.
        TYPE_WEIGHTS = {
          "CITY" => 100, "TOWN" => 90, "MUN1" => 85, "VILG" => 80, "PARK" => 75, "HAM" => 70, "MTN" => 65, "UNP" => 60,
          "GLAC" => 55, "LAKE" => 50, "RIV" => 48, "RECR" => 45, "CAMP" => 45, "VALL" => 42, "BAY" => 40, "ISL" => 40,
          "MUN2" => 40, "PROV" => 110, "TERR" => 110
        }.freeze
        DEFAULT_WEIGHT = 30
        REQUIRED_COLUMNS = ["Geographical Name", "Generic Term", "Generic Category", "Concise Code", "Latitude", "Longitude",
                            "Province - Territory", "Relevance at Scale"].freeze

        def self.weight(code, relevance)
          prominence = relevance.to_i.positive? ? Math.log10(relevance.to_i / 50_000.0).clamp(0, 3) * 10 : 0
          TYPE_WEIGHTS.fetch(code, DEFAULT_WEIGHT) + prominence.round(2)
        end

        def initialize(logger:)
          @logger = logger
        end

        # io yields the CSV text (a File, StringIO or an Enumerator of chunks via #each_line). source is recorded in meta.
        def build(io, path, source:)
          FileUtils.mkdir_p(File.dirname(path))
          temp = "#{path}.#{Process.pid}.tmp"
          FileUtils.rm_f(temp)
          count = write(io, temp, source)
          raise BuildError, "the gazetteer CSV contained no places" if count.zero?

          File.rename(temp, path)
          @logger.info("gazetteer_built", path:, places: count, bytes: File.size(path))
          count
        ensure
          FileUtils.rm_f(temp) if temp
        end

        private

        def write(io, temp, source)
          db = SQLite3::Database.new(temp)
          db.execute_batch(<<~SQL)
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE places (id INTEGER PRIMARY KEY, name TEXT NOT NULL, key TEXT NOT NULL, generic TEXT, category TEXT,
                                 code TEXT, province TEXT, lat REAL NOT NULL, lon REAL NOT NULL, weight REAL NOT NULL);
          SQL
          count = insert_rows(db, io)
          db.execute_batch(<<~SQL)
            CREATE INDEX places_key ON places (key);
            CREATE INDEX places_lat ON places (lat, lon);
            CREATE VIRTUAL TABLE places_fts USING fts5 (name, content = 'places', content_rowid = 'id',
                                                        tokenize = 'unicode61 remove_diacritics 2');
            INSERT INTO places_fts (places_fts) VALUES ('rebuild');
            INSERT INTO places_fts (places_fts) VALUES ('optimize');
          SQL
          meta(db, source, count)
          db.execute("VACUUM")
          count
        ensure
          db&.close
        end

        def insert_rows(db, io)
          count = 0
          insert = db.prepare("INSERT INTO places (name, key, generic, category, code, province, lat, lon, weight) " \
                              "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
          db.transaction do
            each_row(io) do |row|
              values = values(row)
              next unless values

              insert.execute(values)
              count += 1
            end
          end
          count
        ensure
          insert&.close
        end

        def each_row(io)
          csv = CSV.new(io, headers: true, liberal_parsing: true, header_converters: ->(header) { header.to_s.delete_prefix("\uFEFF") })
          header_checked = false
          csv.each do |row|
            unless header_checked
              missing = REQUIRED_COLUMNS - row.headers
              raise BuildError, "the gazetteer CSV lacks the columns #{missing.join(", ")}" if missing.any?

              header_checked = true
            end
            yield row
          end
        end

        def values(row)
          name = row["Geographical Name"].to_s.strip
          lat = Float(row["Latitude"], exception: false)
          lon = Float(row["Longitude"], exception: false)
          return if name.empty? || lat.nil? || lon.nil? || !lat.between?(-90, 90) || !lon.between?(-180, 180)

          code = row["Concise Code"].to_s.strip
          [name, Gazetteer.normalize(name), row["Generic Term"], row["Generic Category"], code, row["Province - Territory"],
           lat, lon, self.class.weight(code, row["Relevance at Scale"])]
        end

        def meta(db, source, count)
          { "schema_version" => SCHEMA_VERSION.to_s, "source" => source, "places" => count.to_s,
            "built_at" => Time.now.utc.iso8601 }.each { |key, value| db.execute("INSERT INTO meta VALUES (?, ?)", [key, value.to_s]) }
        end
      end
    end
  end
end
