# frozen_string_literal: true

require "async"
require "async/http/client"
require "async/http/endpoint"
require "async/semaphore"
require "openssl"
require "protocol/http/accept_encoding"
require "time"
require "uri"

module WeatherCanadaMCP
  module Sources
    # Fiber-based GET client for a fixed set of upstream origins (Config#upstreams): one persistent connection pool
    # per origin, a shared concurrency limit, a rate limiter per provider, gzip, an overall deadline per attempt, a cap on the
    # decoded body, and bounded retries on transient failures. Only GET exists: the server is read-only.
    #
    # Callers name an origin (:eccc_api, :geomet, :cgn, :basemap, and :avalanche, :avalanche_weather when enabled) and pass a
    # path with its query; they cannot reach any other host.
    class HttpClient
      RETRY_STATUSES = [429, 502, 503, 504].freeze
      MAX_RETRY_AFTER = 10

      # When a request began and how long it waited for the rate limiter, in seconds.
      Timing = Struct.new(:started, :limiter_wait)

      def initialize(origins:, user_agent:, timeout:, max_concurrency:, max_body_bytes:, rate_limiters:, logger:,
                     max_retries: 2, base_delay: 0.5)
        @origins = origins.to_h { |name, url| [name, Origin.build(name, url)] }
        @user_agent = user_agent
        @timeout = timeout
        @max_body_bytes = max_body_bytes
        @rate_limiters = rate_limiters
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
        uri = URI(self.origin(origin).url)
        raise ArgumentError, "path must start with /" unless path.start_with?("/")

        request_path = "#{uri.path}#{path}"
        headers = [["user-agent", @user_agent], ["accept", accept]]
        timing = Timing.new(Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.0)
        Trace.request
        response = with_retries(uri.host, path) do
          perform(origin, uri, request_path, headers, max_body_bytes || @max_body_bytes, timeout || @timeout, timing)
        end
        log_request(origin, path, timing, status: response.status)
        response
      rescue WeatherCanadaMCP::Error => e
        log_request(origin, path, timing, error: e.class.name.split("::").last) if timing
        raise
      end

      # An answer served from the cache instead of a request, for the debug log and the call's trace.
      def cache_hit(origin, path)
        Trace.hit
        @logger.debug("upstream_request", origin:, resource: RequestLog.resource(path), cache_hit: true)
      end

      # The configured upstream (Sources::Origin) named by key.
      def origin(key) = @origins.fetch(key) { raise ArgumentError, "unknown upstream #{key.inspect}" }

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
          @logger.warn("upstream_retry", host:, path: RequestLog.path_only(path), status: response.status, delay: delay.round(2))
          sleep(delay)
        rescue TransportError => e
          raise unless e.retryable? && attempt < @max_retries

          attempt += 1
          @logger.warn("upstream_retry", host:, path: RequestLog.path_only(path), error: e.cause&.class&.name)
          sleep(backoff(attempt))
        end
      end

      def perform(origin, uri, request_path, headers, limit, timeout, timing) # rubocop:disable Metrics/ParameterLists -- one request's settings
        # The wait for a rate slot comes first, so a throttled provider does not hold a concurrency slot others need.
        # A call may wait for a slot as long as its deadline leaves room: a burst of calls queues instead of being refused.
        timing.limiter_wait += @rate_limiters.acquire(origin, max_wait: Trace.wait_budget || RateLimiter::MAX_WAIT)
        @semaphore.acquire do
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
      rescue WeatherCanadaMCP::Error
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
          TransportError.new("#{host} did not respond within #{timeout} seconds. The service is sometimes slow; retrying later may help.")
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

      def log_request(origin, path, timing, **outcome)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - timing.started
        @logger.debug("upstream_request", origin:, resource: RequestLog.resource(path), **outcome, duration_ms: (elapsed * 1000).round,
                                          limiter_wait_ms: (timing.limiter_wait * 1000).round, cache_hit: false)
      end
    end
  end
end
