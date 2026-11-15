# frozen_string_literal: true

module WeatherCanadaMcp
  module Tools
    # Recent Mountain Information Network (MIN) reports near a point. Only listed fields are copied, so the submitter's
    # username, user id and anything else about them never reach the result; contact details in the text are removed.
    class GetFieldReports < AvalancheBase
      NAME = "get_field_reports"
      TITLE = "Get avalanche field reports"
      DESCRIPTION = <<~TEXT.tr("\n", " ").strip
        Recent public field reports from Avalanche Canada's Mountain Information Network (MIN) near a location: what
        backcountry users saw on a given day (avalanches with their size, aspect, elevation and trigger, signs of
        instability such as whumpfing or shooting cracks, and their comments), newest first. Reports are written by the
        public and are not verified by Avalanche Canada. Who submitted a report is never included, and email addresses
        and phone numbers in the text are replaced by "[contact details removed]". Pass on safety_note.
      TEXT
      MAX_RADIUS_KM = 100
      MAX_DAYS = Sources::AvalancheCanada::MAX_SUBMISSION_DAYS
      MAX_REPORTS = 20
      REMOVED = "[contact details removed]"
      CONTACT_DETAILS = Regexp.union(
        /[\w.%+-]+@[\w-]+(?:\.[\w-]+)+/, # email addresses
        /(?<![\w@])@\w(?:[\w.]{0,28}\w)/, # social media handles
        /(?<!\w)(?:\+?1[\s.-]?)?(?:\(\d{3}\)|\d{3})[\s.-]?\d{3}[\s.-]?\d{4}(?!\w)/ # North American phone numbers
      )
      SUBMISSION_ID = /\A[0-9a-f-]{36}\z/
      # MIN avalanche observation fields => output fields.
      AVALANCHE_FIELDS = {
        "when" => :when, "date" => :date, "size" => :size, "problem" => :problem, "trigger" => :trigger,
        "startedBy" => :started_by, "aspect" => :aspects, "elevation" => :elevation, "crownDepth" => :crown_depth_cm,
        "width" => :width_m, "runLength" => :run_length_m, "startZoneElevation" => :start_zone_elevation_m,
        "incline" => :incline_deg, "weakLayer" => :weak_layers, "crust" => :crust
      }.freeze
      REPORTS_ATTRIBUTION = "Field reports from the public through the Mountain Information Network of Avalanche Canada " \
                            "(avalanche.ca), not verified by Avalanche Canada. #{format(UNOFFICIAL, agencies: AVALANCHE_CANADA)}".freeze
      INPUT_SCHEMA = {
        type: "object",
        properties: {
          **Base::LOCATION_PROPERTIES,
          radius_km: { type: "integer", minimum: 1, maximum: MAX_RADIUS_KM, default: 25, description: "Search radius." },
          days: { type: "integer", minimum: 1, maximum: MAX_DAYS, default: 7, description: "Days to include, today included." },
          limit: { type: "integer", minimum: 1, maximum: MAX_REPORTS, default: 10, description: "Most reports to include." }
        },
        additionalProperties: false
      }.freeze

      def call(arguments)
        point = resolve_point(arguments)
        radius = integer_argument(arguments, "radius_km", 25, 1..MAX_RADIUS_KM)
        days = integer_argument(arguments, "days", 7, 1..MAX_DAYS)
        limit = integer_argument(arguments, "limit", 10, 1..MAX_REPORTS)
        from, to = period(days)
        found = nearby(avalanche.submissions(from:, to:, bbox: Geo.bbox(point.lat, point.lon, radius)), point, radius)
        reports = found.first(limit).map { |distance, item| report(item, distance) }
        { location: point.to_h, from: from.iso8601, to: to.iso8601, reports:, more_reports: (found.size - limit if found.size > limit),
          note: ("No field report within #{radius} km in the past #{days} days." if found.empty?),
          safety_note: safety_note(config.lang), attribution: REPORTS_ATTRIBUTION }
      end

      private

      # Report dates are local. Canadian dates run from UTC-2.5 to UTC-8, so the period ends on today's UTC date and starts
      # days - 1 before today at UTC-8, within MIN's 31-day limit.
      def period(days)
        to = now.utc.to_date
        from = [LocalTime.date(now, nil) - (days - 1), to - (MAX_DAYS - 1)].max
        [from, to]
      end

      # [[distance_km, item], ...] within the radius, newest first.
      def nearby(items, point, radius)
        found = items.filter_map do |item|
          lat = field(item, "location", "latitude") if item.is_a?(Hash)
          lon = field(item, "location", "longitude") if item.is_a?(Hash)
          next unless lat.is_a?(Numeric) && lon.is_a?(Numeric)

          distance = Geo.distance_km(point.lat, point.lon, lat, lon)
          [distance, item] if distance <= radius
        end
        found.sort_by { |_, item| [item["date"].to_s, item["submissionDatetime"].to_s] }.reverse
      end

      def report(item, distance)
        id = item["submissionID"] if item["submissionID"].to_s.match?(SUBMISSION_ID)
        { id:, url: ("https://avalanche.ca/mountain-information-network/submissions/#{id}" if id), title: redact(item["title"]),
          observed_on: item["date"], submitted_at: time(item["submissionDatetime"])&.utc&.iso8601, region: item["region"],
          distance_km: round_km(distance),
          location: { lat: field(item, "location", "latitude").round(3), lon: field(item, "location", "longitude").round(3) },
          **observations(item), comments: redact(item["comments"]), image_count: number(item["imageCount"]) }
      end

      def observations(item)
        { activities: strings(item["activities"]), other_activity: redact(item["activityOther"]),
          saw_avalanche: scalar(item["sawAvalanche"]), caught_in_avalanche: scalar(item["caught"]), instability: strings(item["instability"]),
          avalanches: Array(item["avalanches"]).filter_map { |observation| observed_avalanche(observation) if observation.is_a?(Hash) } }
      end

      def observed_avalanche(observation)
        AVALANCHE_FIELDS.to_h do |field, key|
          value = observation[field]
          [key, value.is_a?(Array) ? strings(value) : scalar(value)]
        end
      end

      def strings(value) = Array(value).grep(String)

      def scalar(value) = (value if value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false)

      def redact(value) = (value.gsub(CONTACT_DETAILS, REMOVED).strip if value.is_a?(String))
    end
  end
end
