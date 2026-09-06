# frozen_string_literal: true

module ProviderCompiler
  module Mapping
    module Transformations
      module DateTime
        module_function

        def descriptor(format:)
          { "type" => "date_time", "format" => format.to_s }
        end

        def infer(schema)
          return unless schema&.format.to_s.casecmp?("date-time")

          descriptor(format: schema.format)
        end
      end
    end
  end
end
