# frozen_string_literal: true

module ProviderCompiler
  module OpenAPI
    class Normalizer
      def call(value)
        normalize(value)
      end

      private

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[key.to_s] = normalize(item)
          end
        when Array
          value.map { |item| normalize(item) }
        else
          value
        end
      end
    end
  end
end
