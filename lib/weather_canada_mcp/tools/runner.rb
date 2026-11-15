# frozen_string_literal: true

require "json"
require "mcp"

module WeatherCanadaMCP
  module Tools
    # Runs tool calls and shapes results for an assistant: compact JSON without nulls or empty values, the licence
    # attribution, and a size cap. Argument problems and upstream failures become tool errors the model can read,
    # never protocol errors.
    class Runner
      ANNOTATIONS = { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: true }.freeze
      # A call that takes longer is stopped, and calls beyond MAX_CALLS at once are refused, so a slow upstream cannot pile
      # up work. Both are seconds and counts per server process.
      DEADLINE = 45
      MAX_CALLS = 8

      # Raised into a call that ran out of time. HttpClient lets every WeatherCanadaMCP::Error through, so it is not taken
      # for a failed request.
      class DeadlineExceeded < WeatherCanadaMCP::Error; end

      def initialize(context:, logger:, max_response_bytes:, deadline: DEADLINE, max_calls: MAX_CALLS)
        @context = context
        @logger = logger
        @max_response_bytes = max_response_bytes
        @deadline = deadline
        @max_calls = max_calls
        @active = 0
      end

      def mcp_tool(tool_class)
        runner = self
        MCP::Tool.define(
          name: tool_class.tool_name, title: tool_class.title, description: tool_class.description,
          input_schema: tool_class.input_schema, annotations: ANNOTATIONS.merge(title: tool_class.title)
        ) { |**arguments| runner.call(tool_class, arguments.except(:server_context)) }
      end

      # A new tool instance serves each call, so a tool may keep state in instance variables. The call's trace counts its
      # upstream requests and cache hits for the log.
      def call(tool_class, arguments)
        Sources::Trace.around { |trace| call_traced(tool_class, arguments, trace) }
      end

      private

      def call_traced(tool_class, arguments, trace)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return busy(tool_class, started) if @active >= @max_calls

        run(tool_class, arguments, started, trace)
      rescue MCP::CancelledError
        raise
      rescue DeadlineExceeded, Tools::Error, Sources::Error => e
        failed(tool_class, started, e, trace)
      rescue StandardError => e
        unexpected(tool_class, started, e, trace)
      end

      def run(tool_class, arguments, started, trace)
        result = counted { within_deadline { tool_class.new(@context).run(arguments.transform_keys(&:to_s)) } }
        log(tool_class, started, trace)
        json = render(result)
        json.bytesize <= @max_response_bytes ? content(json, result.image) : error(too_large(json.bytesize, tool_class))
      end

      # A tool error carries its own message; an upstream failure and a deadline also credit the source.
      def failed(tool_class, started, exception, trace)
        log(tool_class, started, trace, error: exception.class.name.split("::").last)
        case exception
        when Tools::Error then error(exception.message)
        when DeadlineExceeded
          error("This took longer than #{@deadline} seconds and was stopped. The data services may be slow; try again, or ask " \
                "for less. #{tool_class.attribution}")
        else error("#{exception.message} #{tool_class.attribution}")
        end
      end

      def counted
        @active += 1
        yield
      ensure
        @active -= 1
      end

      # Without a reactor (a plain call from a script) there is nothing to interrupt the call with, so it just runs.
      def within_deadline(&)
        task = Async::Task.current?
        task ? task.with_timeout(@deadline, DeadlineExceeded, &) : yield
      end

      def busy(tool_class, started)
        log(tool_class, started, nil, error: "TooManyCalls")
        error("This server is already running #{@max_calls} tool calls; try again in a few seconds.")
      end

      # The credits are joined as the tool and the point resolution declared them (Tools::Result#attributions).
      def render(result) = JSON.generate(compact(result.data.merge(attribution: result.attributions.join(" "))))

      # Results over the cap are never cut mid-way, since alert text must stay whole.
      def too_large(size, tool_class)
        "The result is #{size} bytes, over this server's #{@max_response_bytes}-byte limit (WEATHER_MCP_MAX_RESPONSE_BYTES). " \
          "Ask for less (fewer hours, a smaller limit). #{tool_class.attribution}"
      end

      def compact(value)
        case value
        when Hash
          hash = value.each_with_object({}) { |(key, item), out| (item = compact(item)).nil? || (out[key] = item) }
          hash.empty? ? nil : hash
        when Array then value.filter_map { |item| compact(item) }
        when String then value.empty? ? nil : value
        else value
        end
      end

      # A bug, not an upstream failure. Only the class is logged: the message could quote a response.
      def unexpected(tool_class, started, exception, trace)
        log(tool_class, started, trace, error: exception.class.name)
        @logger.error("tool_exception", tool: tool_class.tool_name, error: exception.class.name,
                                        location: exception.backtrace_locations&.first&.then { |l| "#{File.basename(l.path)}:#{l.lineno}" })
        error("The server failed unexpectedly while handling this request (#{exception.class.name}). " \
              "This is a bug in the MCP server, not an ECCC problem.")
      end

      # The JSON, and the image a tool returned (Tools::Image), which the response size cap does not count.
      def content(json, image)
        parts = [{ type: "text", text: json }]
        parts << { type: "image", data: [image.data].pack("m0"), mimeType: image.mime_type } if image.is_a?(Tools::Image)
        MCP::Tool::Response.new(parts)
      end

      def error(message) = MCP::Tool::Response.new([{ type: "text", text: message }], error: true)

      def log(tool_class, started, trace, **fields)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        counts = trace ? { upstream_requests: trace.requests, cache_hits: trace.cache_hits } : {}
        @logger.info("tool_call", tool: tool_class.tool_name, duration_ms:, **counts, **fields)
      end
    end
  end
end
