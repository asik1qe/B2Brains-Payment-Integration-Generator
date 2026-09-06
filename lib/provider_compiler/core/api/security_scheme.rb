# frozen_string_literal: true

module ProviderCompiler
  module Core
    module API
      class SecurityScheme
        ATTRIBUTES = %i[key type location name scheme bearer_format description extensions].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          key:,
          type:,
          location: nil,
          name: nil,
          scheme: nil,
          bearer_format: nil,
          description: nil,
          extensions: {}
        )
          raise ArgumentError, "key must not be empty" if empty?(key)
          raise ArgumentError, "type must not be empty" if empty?(type)

          @key = key
          @type = type
          @location = location
          @name = name
          @scheme = scheme
          @bearer_format = bearer_format
          @description = description
          @extensions = string_keyed_copy(extensions)
        end

        def api_key? = type.to_s.casecmp?("apiKey")
        def http? = type.to_s.casecmp?("http")
        def bearer? = http? && scheme.to_s.casecmp?("bearer")
        def basic? = http? && scheme.to_s.casecmp?("basic")

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
