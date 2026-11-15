# frozen_string_literal: true

module WeatherCanadaMCP
  module Tools
    # One declared tool argument. It produces the JSON schema property and, as a second layer behind the MCP SDK's own
    # schema check, parses the value: type, range or allowed values, and the default.
    #
    #   argument :hours, :integer, in: 0..24, default: 12, description: "..."
    #
    # Types: :integer and :number (`in:` a Range), :string (`max_length:`, `pattern:`, `in:` an Array) and :language
    # (en or fr, the configured language when missing). `bounds:` puts a range in the schema without enforcing it, for a
    # check the tool words better itself. A pattern appears in the schema only.
    class Argument
      TYPES = %i[integer number string language].freeze
      LANGUAGE_DESCRIPTION = "Language of text fields: en or fr."

      attr_reader :name, :type, :default

      def initialize(name, type, **options)
        raise ArgumentError, "unknown argument type #{type.inspect}" unless TYPES.include?(type)

        @name = name
        @type = type
        @allowed = options[:in]
        @bounds = options[:bounds] || (@allowed if @allowed.is_a?(Range))
        @max_length = options[:max_length]
        @pattern = options[:pattern]
        @default = options[:default]
        @description = type == :language ? LANGUAGE_DESCRIPTION : options[:description]
        freeze
      end

      def schema
        schema = { type: json_type }
        if type == :language
          schema[:enum] = Config::LANGS
        elsif @allowed.is_a?(Array)
          schema[:enum] = @allowed
        end
        schema.merge!(minimum: @bounds.min, maximum: @bounds.max) if @bounds
        schema[:maxLength] = @max_length if @max_length
        schema[:pattern] = @pattern.source.sub("\\A", "^").sub("\\z", "$") if @pattern
        schema[:default] = @default unless @default.nil?
        schema[:description] = @description
        schema
      end

      # The checked value, or the default when missing (nil). config supplies the default language.
      def parse(value, config)
        return default_value(config) if value.nil?

        case type
        when :integer then integer(value)
        when :number then number(value)
        when :string then string(value)
        when :language then language(value)
        end
      end

      private

      def json_type = type == :language ? "string" : type.to_s

      def default_value(config) = type == :language ? config&.lang : @default

      def integer(value)
        value = value.to_i if value.is_a?(Float) && value.finite? && (value % 1).zero? # JSON Schema counts 2.0 as an integer
        return value if value.is_a?(Integer) && allowed?(value)

        raise InvalidArguments, @allowed.is_a?(Array) ? one_of : "#{name} must be a whole number from #{@allowed.min} to #{@allowed.max}."
      end

      def number(value)
        raise InvalidArguments, "#{name} must be a number." unless value.is_a?(Numeric) && value.to_f.finite?
        raise InvalidArguments, "#{name} must be from #{@allowed.min} to #{@allowed.max}." unless allowed?(value)

        value
      end

      def string(value)
        raise InvalidArguments, "#{name} must be text." unless value.is_a?(String)
        raise InvalidArguments, "#{name} is longer than #{@max_length} characters." if @max_length && value.length > @max_length
        raise InvalidArguments, one_of unless allowed?(value)

        value
      end

      def language(value) = Config::LANGS.include?(value) ? value : raise(InvalidArguments, "#{name} must be en or fr")

      def allowed?(value)
        case @allowed
        when Range then @allowed.cover?(value)
        when Array then @allowed.include?(value)
        else true
        end
      end

      def one_of = "#{name} must be one of #{@allowed.join(", ")}."
    end
  end
end
