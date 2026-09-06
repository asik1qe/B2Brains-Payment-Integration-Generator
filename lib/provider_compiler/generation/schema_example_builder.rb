# frozen_string_literal: true

module ProviderCompiler
  module Generation
    class SchemaExampleBuilder
      def build(schema)
        return nil unless schema
        return deep_copy(schema.example) unless schema.example.nil?
        return deep_copy(schema.enum.first) if schema.enum&.any?

        case schema.type.to_s.downcase
        when "object"
          schema.properties.each_with_object({}) do |(name, child), result|
            result[name.to_s] = build(child)
          end
        when "array"
          schema.items ? [build(schema.items)] : []
        when "string"
          string_example(schema.format)
        when "integer", "number"
          schema.minimum || 0
        when "boolean"
          true
        else
          nil
        end
      end

      private

      def string_example(format)
        case format.to_s.downcase
        when "uuid" then "00000000-0000-0000-0000-000000000000"
        when "date-time" then "2026-01-01T00:00:00Z"
        when "date" then "2026-01-01"
        else "string"
        end
      end

      def deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = deep_copy(item) }
        when Array
          value.map { |item| deep_copy(item) }
        else
          value
        end
      end
    end
  end
end
