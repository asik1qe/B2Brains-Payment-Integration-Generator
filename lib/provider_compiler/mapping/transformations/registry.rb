# frozen_string_literal: true

require_relative "money"
require_relative "date_time"
require_relative "enum"
require_relative "nested_object"
require_relative "type_cast"

module ProviderCompiler
  module Mapping
    module Transformations
      module Registry
        TYPES = {
          "money" => Money,
          "date_time" => DateTime,
          "enum" => Enum,
          "nested_object" => NestedObject,
          "type_cast" => TypeCast
        }.freeze

        module_function

        def fetch(type) = TYPES[type.to_s]
        def registered?(type) = TYPES.key?(type.to_s)
        def types = TYPES.keys.freeze
      end
    end
  end
end
