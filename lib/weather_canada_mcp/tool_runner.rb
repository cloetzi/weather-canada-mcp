# frozen_string_literal: true

require "json"
require "mcp"

module WeatherCanadaMcp
  # Runs tool calls and shapes results for an assistant: compact JSON without nulls or empty values, the licence
  # attribution, and a size cap. Argument problems and upstream failures become tool errors the model can read,
  # never protocol errors.
  class ToolRunner
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
      text(render(result))
    rescue Tools::InvalidArguments => e
      log(tool, started, error: "InvalidArguments")
      error(e.message)
    rescue Upstream::Error => e
      log(tool, started, error: e.class.name.split("::").last)
      error("#{e.message} #{ATTRIBUTION}")
    rescue MCP::CancelledError
      raise
    rescue StandardError => e
      unexpected(tool, started, e)
    end

    private

    def render(result)
      json = JSON.generate(compact(result.merge(attribution: attribution(result))))
      return json if json.bytesize <= @max_response_bytes

      # Never cut JSON mid-way (alert text must stay whole): say what was too large instead.
      JSON.generate(error: "The result is #{json.bytesize} bytes, over this server's #{@max_response_bytes}-byte limit. " \
                           "Ask for less (fewer hours, a smaller limit).", attribution: ATTRIBUTION)
    end

    def attribution(result)
      if result.key?(:candidates) || result.key?(:nearby_places) || result.dig(:location,
                                                                               :query_match)
        "#{ATTRIBUTION} #{Gazetteer::ATTRIBUTION}"
      else
        ATTRIBUTION
      end
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
