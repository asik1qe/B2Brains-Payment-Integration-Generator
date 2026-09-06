# frozen_string_literal: true

module ProviderCompiler
  module Mapping
    module Transformations
      module NestedObject
        module_function

        def descriptor(provider_path:, field_mappings: nil)
          result = { "type" => "nested_object", "provider_path" => provider_path.to_s }
          result["field_mappings"] = deep_copy(field_mappings) unless field_mappings.nil?
          result
        end

        def get(value, path)
          path.to_s.split(".").reduce(value) do |current, token|
            break nil unless current.is_a?(Hash)

            current.key?(token) ? current[token] : current[token.to_sym]
          end
        end

        def set(value, path, new_value)
          copy = deep_copy(value)
          tokens = path.to_s.split(".")
          return copy if tokens.empty? || tokens.any?(&:empty?)

          current = copy
          tokens[0...-1].each do |token|
            key = current.key?(token) ? token : (current.key?(token.to_sym) ? token.to_sym : token)
            child = current[key]
            child = {} unless child.is_a?(Hash)
            current[key] = deep_copy(child)
            current = current[key]
          end
          leaf = tokens.last
          leaf_key = current.key?(leaf) ? leaf : (current.key?(leaf.to_sym) ? leaf.to_sym : leaf)
          current[leaf_key] = deep_copy(new_value)
          copy
        end

        def deep_copy(value)
          case value
          when Hash then value.each_with_object({}) { |(key, item), result| result[key] = deep_copy(item) }
          when Array then value.map { |item| deep_copy(item) }
          else value
          end
        end
        private_class_method :deep_copy
      end
    end
  end
end
