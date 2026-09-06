# frozen_string_literal: true

require_relative "schema"

module ProviderCompiler
  module Core
    module API
      class Parameter
        ATTRIBUTES = %i[name location required schema description example deprecated extensions].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          name:,
          location:,
          required: false,
          schema: nil,
          description: nil,
          example: nil,
          deprecated: false,
          extensions: {}
        )
          raise ArgumentError, "name must not be empty" if empty?(name)
          raise ArgumentError, "location must not be empty" if empty?(location)

          @name = name
          @location = location.to_s.downcase
          @required = required
          @schema = schema
          @description = description
          @example = example
          @deprecated = deprecated
          @extensions = string_keyed_copy(extensions)
        end

        def path? = location == "path"
        def query? = location == "query"
        def header? = location == "header"
        def cookie? = location == "cookie"

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

        def empty?(value)
          value.nil? || value.to_s.empty?
        end

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
