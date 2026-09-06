# frozen_string_literal: true

require_relative "ref_resolver"
require_relative "../core/api/schema"
require_relative "../core/diagnostic"

module ProviderCompiler
  module OpenAPI
    class SchemaParser
      COMPOSITION_FEATURES = %w[oneOf anyOf allOf not].freeze

      def initialize(document, ref_resolver: nil)
        @ref_resolver = ref_resolver || RefResolver.new(document)
        @diagnostics = []
      end

      def diagnostics
        (@diagnostics + @ref_resolver.diagnostics).uniq
      end

      def parse(raw_schema, name: nil, ref_stack: [])
        return nil if raw_schema.nil?

        unless raw_schema.is_a?(Hash)
          add_invalid_schema(raw_schema)
          return nil
        end

        raw = stringify_keys(raw_schema)
        ref = raw["$ref"]
        return parse_reference(ref, name: name, ref_stack: ref_stack, raw: raw) if ref

        build_schema(raw, name: name, ref_stack: ref_stack)
      end

      private

      def parse_reference(ref, name:, ref_stack:, raw:)
        inferred_name = name || component_name(ref)

        if ref_stack.include?(ref)
          @diagnostics << ProviderCompiler::Core::Diagnostic.new(
            severity: :warning,
            code: :cyclic_ref,
            message: "Cyclic schema reference detected",
            stage: :openapi,
            state: :needs_review,
            location: ref
          )
          return ProviderCompiler::Core::API::Schema.new(
            name: inferred_name,
            ref: ref,
            unsupported_features: ["cyclic_ref"],
            extensions: extract_extensions(raw)
          )
        end

        target = @ref_resolver.resolve(ref)
        unless target.is_a?(Hash)
          return ProviderCompiler::Core::API::Schema.new(
            name: inferred_name,
            ref: ref,
            extensions: extract_extensions(raw)
          )
        end

        resolved = parse(target, name: inferred_name, ref_stack: ref_stack + [ref])
        return nil if resolved.nil?

        copy_with_reference(resolved, ref, inferred_name, extract_extensions(raw))
      end

      def build_schema(raw, name:, ref_stack:)
        ProviderCompiler::Core::API::Schema.new(
          name: name,
          type: raw["type"],
          format: raw["format"],
          description: raw["description"],
          properties: parse_properties(raw["properties"], ref_stack),
          items: parse(raw["items"], ref_stack: ref_stack),
          required: raw["required"].is_a?(Array) ? raw["required"] : [],
          enum: raw["enum"].is_a?(Array) ? raw["enum"] : nil,
          minimum: raw["minimum"],
          maximum: raw["maximum"],
          min_length: raw["minLength"],
          max_length: raw["maxLength"],
          pattern: raw["pattern"],
          nullable: raw.key?("nullable") ? raw["nullable"] : false,
          example: raw["example"],
          ref: nil,
          additional_properties: parse_additional_properties(raw["additionalProperties"], ref_stack),
          unsupported_features: COMPOSITION_FEATURES.select { |feature| raw.key?(feature) },
          extensions: extract_extensions(raw)
        )
      end

      def parse_properties(raw_properties, ref_stack)
        return {} unless raw_properties.is_a?(Hash)

        raw_properties.each_with_object({}) do |(property_name, raw_property), result|
          schema = parse(raw_property, name: nil, ref_stack: ref_stack)
          result[property_name.to_s] = schema unless schema.nil?
        end
      end

      def parse_additional_properties(value, ref_stack)
        return value if value == true || value == false || value.nil?
        return parse(value, ref_stack: ref_stack) if value.is_a?(Hash)

        add_invalid_schema(value, location: "additionalProperties")
        nil
      end

      def copy_with_reference(schema, ref, name, extensions)
        ProviderCompiler::Core::API::Schema.new(
          name: name || schema.name,
          type: schema.type,
          format: schema.format,
          description: schema.description,
          properties: schema.properties,
          items: schema.items,
          required: schema.required,
          enum: schema.enum,
          minimum: schema.minimum,
          maximum: schema.maximum,
          min_length: schema.min_length,
          max_length: schema.max_length,
          pattern: schema.pattern,
          nullable: schema.nullable,
          example: schema.example,
          ref: ref,
          additional_properties: schema.additional_properties,
          unsupported_features: schema.unsupported_features,
          extensions: schema.extensions.merge(extensions)
        )
      end

      def component_name(ref)
        return unless ref.is_a?(String) && ref.start_with?("#/components/schemas/")

        token = ref.split("/").last
        token&.gsub("~1", "/")&.gsub("~0", "~")
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end

      def extract_extensions(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key] = value if key.start_with?("x-")
        end
      end

      def add_invalid_schema(value, location: nil)
        @diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: :invalid_schema,
          message: "Schema must be an object, got #{value.class}",
          stage: :openapi,
          state: :unresolved,
          location: location
        )
      end
    end
  end
end
