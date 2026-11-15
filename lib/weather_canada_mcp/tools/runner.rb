# frozen_string_literal: true

require "json"
require "mcp"

module WeatherCanadaMcp
  module Tools
    # Runs tool calls and shapes results for an assistant: compact JSON without nulls or empty values, the licence
    # attribution, and a size cap. Argument problems and upstream failures become tool errors the model can read,
    # never protocol errors.
    class Runner
      ANNOTATIONS = { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: true }.freeze

      def initialize(context:, logger:, max_response_bytes:)
        @context = context
        @logger = logger
        @max_response_bytes = max_response_bytes
      end

      def mcp_tool(tool_class)
        runner = self
        tool = tool_class.new(@context)
        MCP::Tool.define(
          name: tool_class.tool_name, title: tool_class.title, description: tool_class.description,
          input_schema: tool_class.input_schema, annotations: ANNOTATIONS.merge(title: tool_class.title)
        ) { |**arguments| runner.call(tool, arguments.except(:server_context)) }
      end

      def call(tool, arguments)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = tool.call(arguments.transform_keys(&:to_s))
        log(tool, started)
        json = render(result, tool.class)
        json.bytesize <= @max_response_bytes ? text(json) : error(too_large(json.bytesize, tool.class))
      rescue Tools::InvalidArguments => e
        log(tool, started, error: "InvalidArguments")
        error(e.message)
      rescue Sources::Error => e
        log(tool, started, error: e.class.name.split("::").last)
        error("#{e.message} #{tool.class.attribution}")
      rescue MCP::CancelledError
        raise
      rescue StandardError => e
        unexpected(tool, started, e)
      end

      private

      def render(result, tool_class) = JSON.generate(compact(result.merge(attribution: attribution(result, tool_class))))

      # Results over the cap are never cut mid-way, since alert text must stay whole.
      def too_large(size, tool_class)
        "The result is #{size} bytes, over this server's #{@max_response_bytes}-byte limit (WEATHER_MCP_MAX_RESPONSE_BYTES). " \
          "Ask for less (fewer hours, a smaller limit). #{tool_class.attribution}"
      end

      # The tool's attribution (or the one its result names), plus NRCan's when place names were used.
      def attribution(result, tool_class)
        source = result[:attribution] || tool_class.attribution
        place_names = result.key?(:candidates) || result.key?(:nearby_places) || result.dig(:location, :query_match)
        place_names ? "#{source} #{Places::Gazetteer::ATTRIBUTION}" : source
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
      def unexpected(tool, started, exception)
        log(tool, started, error: exception.class.name)
        @logger.error("tool_exception", tool: tool.class.tool_name, error: exception.class.name,
                                        location: exception.backtrace_locations&.first&.then { |l| "#{File.basename(l.path)}:#{l.lineno}" })
        error("The server failed unexpectedly while handling this request (#{exception.class.name}). " \
              "This is a bug in the MCP server, not an ECCC problem.")
      end

      def text(content) = MCP::Tool::Response.new([{ type: "text", text: content }])

      def error(message) = MCP::Tool::Response.new([{ type: "text", text: message }], error: true)

      def log(tool, started, **fields)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        @logger.info("tool_call", tool: tool.class.tool_name, duration_ms:, **fields)
      end
    end
  end
end
