# frozen_string_literal: true

require "async"
require "async/http/client"
require "async/http/endpoint"
require "async/semaphore"
require "openssl"
require "protocol/http/accept_encoding"
require "time"
require "uri"

module WeatherCanadaMcp
  module Sources
    # Fiber-based GET client for a fixed set of upstream origins (Config#upstreams): one persistent connection pool
    # per origin, a shared concurrency limit and rate limiter, gzip, an overall deadline per attempt, a cap on the
    # decoded body, and bounded retries on transient failures. Only GET exists: the server is read-only.
    #
    # Callers name an origin (:api, :datamart, :geomet, :cgn) and pass a path with its query; they cannot reach
    # any other host.
    class HttpClient
      RETRY_STATUSES = [429, 502, 503, 504].freeze
      MAX_RETRY_AFTER = 10

      def initialize(origins:, user_agent:, timeout:, max_concurrency:, max_body_bytes:, rate_limiter:, logger:,
                     max_retries: 2, base_delay: 0.5)
        @origins = origins.to_h { |name, url| [name, URI(url)] }
        @user_agent = user_agent
        @timeout = timeout
        @max_body_bytes = max_body_bytes
        @rate_limiter = rate_limiter
        @logger = logger
        @max_retries = max_retries
        @base_delay = base_delay
        @semaphore = Async::Semaphore.new(max_concurrency)
        @clients = {}
      end

      # path includes the query string and is relative to the origin's URL (which may carry a path prefix).
      # max_body_bytes and timeout override the defaults for this request (the gazetteer download is larger and slower
      # than any API reply).
      def get(origin, path, accept: "application/json", max_body_bytes: nil, timeout: nil)
        uri = @origins.fetch(origin) { raise ArgumentError, "unknown upstream #{origin.inspect}" }
        raise ArgumentError, "path must start with /" unless path.start_with?("/")

        request_path = "#{uri.path}#{path}"
        headers = [["user-agent", @user_agent], ["accept", accept]]
        with_retries(uri.host, path) do
          perform(origin, uri, request_path, headers, max_body_bytes || @max_body_bytes, timeout || @timeout)
        end
      end

      def close
        @clients.each_value(&:close)
        @clients.clear
      end

      private

      def with_retries(host, path)
        attempt = 0
        loop do
          response, retry_after = yield
          delay = retry_delay(retry_after, attempt) if RETRY_STATUSES.include?(response.status)
          return response unless delay

          attempt += 1
          @logger.warn("upstream_retry", host:, path: path_only(path), status: response.status, delay: delay.round(2))
          sleep(delay)
        rescue TransportError => e
          raise unless e.retryable? && attempt < @max_retries

          attempt += 1
          @logger.warn("upstream_retry", host:, path: path_only(path), error: e.cause&.class&.name)
          sleep(backoff(attempt))
        end
      end

      def perform(origin, uri, request_path, headers, limit, timeout) # rubocop:disable Metrics/ParameterLists -- one request's settings
        @semaphore.acquire do
          @rate_limiter.acquire
          Async::Task.current.with_timeout(timeout) do
            response = client(origin, uri).call(Protocol::HTTP::Request["GET", request_path, Protocol::HTTP::Headers[headers]])
            begin
              [Response.new(status: response.status, content_type: response.headers["content-type"]&.to_s,
                            body: read_body(response, limit)),
               parse_retry_after(response.headers["retry-after"])]
            ensure
              response.close
            end
          end
        end
      rescue Error
        raise
      rescue StandardError => e
        raise transport_error(e, uri.host, timeout)
      end

      def client(origin, uri)
        @clients[origin] ||= begin
          endpoint = Async::HTTP::Endpoint.parse("#{uri.scheme}://#{uri.host}:#{uri.port}", timeout: @timeout)
          Protocol::HTTP::AcceptEncoding.new(Async::HTTP::Client.new(endpoint))
        end
      end

      # Messages name the failure and the host, never the exception message, which can quote the response.
      # A timeout already used a whole attempt and TLS failures are configuration, so neither is retried.
      def transport_error(error, host, timeout)
        case error
        when Async::TimeoutError, IO::TimeoutError
          TransportError.new("#{host} did not respond within #{timeout} seconds. ECCC services are sometimes slow; retrying later may help.")
        when OpenSSL::SSL::SSLError
          reason = error.message[/[^:]+\z/].to_s.strip[0, 120]
          TransportError.new("The TLS connection to #{host} failed (#{reason}). Check the CA certificates, the system clock " \
                             "and any TLS-intercepting proxy.")
        when SocketError
          TransportError.new("Could not resolve #{host} (#{error.class}). Check DNS and network access.", retryable: true)
        when SystemCallError, IOError, Protocol::HTTP::Error
          TransportError.new("Could not reach #{host} (#{error.class}). Check network access; retrying later may help.",
                             retryable: true)
        else
          TransportError.new("The request to #{host} failed unexpectedly (#{error.class}).")
        end
      end

      # content-length is the encoded size; the cap applies to the decoded body, checked as it streams in.
      def read_body(response, limit)
        declared = response.headers["content-length"]&.to_i
        raise ResponseTooLarge, limit if declared && declared > limit

        buffer = String.new(encoding: Encoding::BINARY)
        response.body&.each do |chunk|
          buffer << chunk
          raise ResponseTooLarge, limit if buffer.bytesize > limit
        end
        buffer
      end

      def retry_delay(retry_after, attempt)
        return if attempt >= @max_retries

        delay = retry_after || backoff(attempt + 1)
        delay if delay <= MAX_RETRY_AFTER
      end

      # Retry-After is delay-seconds or an HTTP date.
      def parse_retry_after(value)
        return if value.nil?

        value = value.to_s
        return Float(value).clamp(0, Float::INFINITY) if value.match?(/\A\d+(\.\d+)?\z/)

        (Time.httpdate(value) - Time.now).clamp(0, Float::INFINITY)
      rescue ArgumentError
        nil
      end

      def backoff(attempt) = (@base_delay * (2**(attempt - 1))) + rand(0.0..@base_delay)

      # Logs keep the collection but never the query (a bbox) or an item id (a forecast site): both reveal locations.
      def path_only(path) = path.split("?", 2).first.sub(%r{/items/.*\z}, "/items/{id}")
    end
  end
end
