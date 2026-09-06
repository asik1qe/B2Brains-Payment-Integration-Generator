# frozen_string_literal: true

module ProviderCompiler
  module Mapping
    module Transformations
      module Enum
        module_function

        def descriptor(mapping:)
          { "type" => "enum", "mapping" => stringify(mapping) }
        end

        def map(value, mapping:)
          stringify(mapping)[value.to_s]
        end

        def reverse_map(value, mapping:)
          stringify(mapping).find { |_provider, internal| internal == value }&.first
        end

        def stringify(mapping)
          mapping.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
        end
        private_class_method :stringify
      end
    end
  end
end
