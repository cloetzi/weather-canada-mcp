# frozen_string_literal: true

module WeatherCanadaMCP
  # Everything that fetches ECCC and NRCan data: the shared HTTP client, the rate limiters (one per provider), the TTL cache and
  # a thin client per service, which returns parsed Ruby data and raises the errors below.
  module Sources
    # Base of every failure fetching data. Messages are written for the model and never quote a response body.
    class Error < WeatherCanadaMCP::Error
      # Whether the service could not be reached or answered with a failure of its own, so that an older copy of the data
      # is better than none. A 404, a rejected request or a reply in an unexpected shape is not that.
      def unreachable? = false
    end

    # The connection failed or timed out. retryable? marks failures worth retrying (connection refused, reset, DNS).
    class TransportError < Error
      def initialize(message, retryable: false)
        super(message)
        @retryable = retryable
      end

      def retryable? = @retryable
      def unreachable? = true
    end

    # The body exceeded the byte limit and was not read further.
    class ResponseTooLarge < Error
      attr_reader :limit

      def initialize(limit)
        @limit = limit
        super("The upstream response is larger than #{limit} bytes, the most this server reads.")
      end
    end

    # The upstream answered with a status that is not 2xx.
    class StatusError < Error
      attr_reader :status

      def initialize(status, host)
        @status = status
        super(self.class.message_for(status, host))
      end

      def unreachable? = status >= 500 || status == 429

      def self.message_for(status, host)
        case status
        when 404 then "#{host} has no data for this request (HTTP 404)."
        when 429 then "#{host} is rate limiting requests (HTTP 429). Wait a minute before retrying."
        when 400..499 then "#{host} rejected the request (HTTP #{status})."
        else "#{host} failed to answer (HTTP #{status}). The service is sometimes briefly unavailable; retrying later may help."
        end
      end
    end

    # A request waited, or would have to wait, too long for its provider's rate limit.
    class Busy < Error
      def initialize(wait)
        super("This server is queuing more requests to the data provider than it may send (a wait of about #{wait.ceil} " \
              "seconds). Try again in a minute.")
      end

      def unreachable? = true
    end

    # The body is not the JSON or XML the source expected.
    class InvalidResponse < Error; end

    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b

    Response = Data.define(:status, :content_type, :body) do
      def success? = (200..299).cover?(status)

      # A PNG image, by its type and signature (WMS servers report errors as XML with a 200).
      def png? = content_type.to_s.start_with?("image/png") && body.start_with?(PNG_SIGNATURE)
    end
  end
end
