# frozen_string_literal: true

module ProviderCompiler
  module Mapping
    module Transformations
      module Money
        FACTORS = { "kopecks" => 100, "cents" => 100 }.freeze

        module_function

        def descriptor(unit:, factor: nil)
          normalized_unit = unit.to_s
          result = { "type" => "money", "unit" => normalized_unit }
          resolved_factor = factor.nil? ? factor_for(normalized_unit) : factor
          result["factor"] = resolved_factor unless resolved_factor.nil?
          result
        end

        def infer_unit(schema)
          text = [schema&.name, schema&.description].compact.join(" ").downcase
          return "kopecks" if text.match?(/\bkopecks?\b|копейк(?:а|и|ах|у|е)?|копеек/)
          return "cents" if text.match?(/\bcents?\b/)
          return "minor_units" if text.match?(/\bminor[ _-]+units?\b/)

          nil
        end

        def factor_for(unit)
          FACTORS[unit.to_s]
        end
      end
    end
  end
end
