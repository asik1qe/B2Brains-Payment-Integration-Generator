# frozen_string_literal: true

require_relative "schema"

module ProviderCompiler
  module Core
    module API
      class RequestBody
        ATTRIBUTES = %i[required content_type schema examples description extensions].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          required: false,
          content_type: nil,
          schema: nil,
          examples: {},
          description: nil,
          extensions: {}
        )
          @required = required
          @content_type = content_type
          @schema = schema
          @examples = string_keyed_copy(examples)
          @description = description
          @extensions = string_keyed_copy(extensions)
        end

        def json?
          !content_type.nil? && content_type.match?(%r{\Aapplication/(?:json|[^;]+\+json)(?:\s*;.*)?\z}i)
        end

        def to_h
          ATTRIBUTES.each_with_object({}) do |attribute, result|
            result[attribute] = serialize(public_send(attribute))
          end
        end

        def ==(other)
          other.instance_of?(self.class) && to_h == other.to_h
        end

        alias eql? ==

        def hash
          [self.class, to_h].hash
        end

        private

        def string_keyed_copy(hash)
          hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        end

        def serialize(value)
          case value
          when Array
            value.map { |item| serialize(item) }
          when Hash
            value.each_with_object({}) { |(key, item), result| result[key] = serialize(item) }
          else
            core_api_object?(value) ? value.to_h : value
          end
        end

        def core_api_object?(value)
          value.class.name.to_s.start_with?("ProviderCompiler::Core::API::") && value.respond_to?(:to_h)
        end
      end
    end
  end
end
