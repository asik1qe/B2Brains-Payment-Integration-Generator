# frozen_string_literal: true

module ProviderCompiler
  module Mapping
    module Transformations
      module TypeCast
        SUPPORTED_TARGETS = %w[string integer number].freeze

        module_function

        def descriptor(to:)
          target = to.to_s.downcase
          raise ArgumentError, "unsupported cast target: #{to.inspect}" unless SUPPORTED_TARGETS.include?(target)

          { "type" => "type_cast", "to" => target }
        end

        def infer(internal_path:, schema:)
          return nil unless schema

          case internal_path.to_s
          when "operation.id", "operation.provider_operation_key"
            return descriptor(to: "string") if schema.type.to_s.casecmp?("string")
          end

          nil
        end
      end
    end
  end
end
