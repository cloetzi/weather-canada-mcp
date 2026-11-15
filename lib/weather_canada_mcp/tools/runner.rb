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

      def initialize(context:, logger:, max_response_bytes:)
        @context = context
        @logger = logger
        @max_response_bytes = max_response_bytes
      end

      def mcp_tool(tool_class)
        runner = self
        MCP::Tool.define(
          name: tool_class.tool_name, title: tool_class.title, description: tool_class.description,
          input_schema: tool_class.input_schema, annotations: ANNOTATIONS.merge(title: tool_class.title)
        ) { |**arguments| runner.call(tool_class, arguments.except(:server_context)) }
      end

      # A new tool instance serves each call, so a tool may keep state in instance variables.
      def call(tool_class, arguments)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = tool_class.new(@context).run(arguments.transform_keys(&:to_s))
        log(tool_class, started)
        json = render(result)
        json.bytesize <= @max_response_bytes ? content(json, result.image) : error(too_large(json.bytesize, tool_class))
      rescue Tools::Error => e
        log(tool_class, started, error: e.class.name.split("::").last)
        error(e.message)
      rescue Sources::Error => e
        log(tool_class, started, error: e.class.name.split("::").last)
        error("#{e.message} #{tool_class.attribution}")
      rescue MCP::CancelledError
        raise
      rescue StandardError => e
        unexpected(tool_class, started, e)
      end

      private

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
      def unexpected(tool_class, started, exception)
        log(tool_class, started, error: exception.class.name)
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

      def log(tool_class, started, **fields)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        @logger.info("tool_call", tool: tool_class.tool_name, duration_ms:, **fields)
      end
    end
  end
end
