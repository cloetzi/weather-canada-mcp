# frozen_string_literal: true

module WeatherCanadaMcp
  # Everything that fetches ECCC and NRCan data: the shared HTTP client, the global rate limiter, the TTL cache and
  # a thin client per service, which returns parsed Ruby data and raises the errors below.
  module Sources
    # Base of every failure fetching data. Messages are written for the model and never quote a response body.
    class Error < WeatherCanadaMcp::Error; end

    # The connection failed or timed out. retryable? marks failures worth retrying (connection refused, reset, DNS).
    class TransportError < Error
      def initialize(message, retryable: false)
        super(message)
        @retryable = retryable
      end

      def retryable? = @retryable
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

      def self.message_for(status, host)
        case status
        when 404 then "#{host} has no data for this request (HTTP 404)."
        when 429 then "#{host} is rate limiting requests (HTTP 429). Wait a minute before retrying."
        when 400..499 then "#{host} rejected the request (HTTP #{status})."
        else "#{host} failed to answer (HTTP #{status}). The service is sometimes briefly unavailable; retrying later may help."
        end
      end
    end

    # The body is not the JSON or XML the source expected.
    class InvalidResponse < Error; end

    Response = Data.define(:status, :content_type, :body) do
      def success? = (200..299).cover?(status)
    end
  end
end
