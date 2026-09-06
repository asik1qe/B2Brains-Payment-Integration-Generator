# frozen_string_literal: true

module ProviderCompiler
  module Core
    module API
      class Schema
        ATTRIBUTES = %i[
          name type format description properties items required enum minimum maximum
          min_length max_length pattern nullable example ref additional_properties
          unsupported_features extensions
        ].freeze
        CONSTRAINTS = %i[minimum maximum min_length max_length pattern].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          name: nil,
          type: nil,
          format: nil,
          description: nil,
          properties: {},
          items: nil,
          required: [],
          enum: nil,
          minimum: nil,
          maximum: nil,
          min_length: nil,
          max_length: nil,
          pattern: nil,
          nullable: false,
          example: nil,
          ref: nil,
          additional_properties: nil,
          unsupported_features: [],
          extensions: {}
        )
          @name = name
          @type = type
          @format = format
          @description = description
          @properties = string_keyed_copy(properties)
          @items = items
          @required = required.map(&:to_s)
          @enum = enum&.dup
          @minimum = minimum
          @maximum = maximum
          @min_length = min_length
          @max_length = max_length
          @pattern = pattern
          @nullable = nullable
          @example = example
          @ref = ref
          @additional_properties = additional_properties
          @unsupported_features = unsupported_features.dup
          @extensions = string_keyed_copy(extensions)
        end

        def object? = type.to_s.casecmp?("object")
        def array? = type.to_s.casecmp?("array")
        def primitive? = !type.nil? && !object? && !array?

        def property(name)
          properties[name.to_s]
        end

        def required?(property_name)
          required.include?(property_name.to_s)
        end

        def enum?
          !enum.nil?
        end

        def constraints
          CONSTRAINTS.each_with_object({}) do |attribute, result|
            value = public_send(attribute)
            result[attribute] = value unless value.nil?
          end
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
