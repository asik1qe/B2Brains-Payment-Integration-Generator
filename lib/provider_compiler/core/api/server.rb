# frozen_string_literal: true

module ProviderCompiler
  module Core
    module API
      class Server
        ATTRIBUTES = %i[url description variables extensions].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(url:, description: nil, variables: {}, extensions: {})
          raise ArgumentError, "url must not be empty" if empty?(url)

          @url = url
          @description = description
          @variables = string_keyed_copy(variables)
          @extensions = string_keyed_copy(extensions)
        end

        def variable(name)
          variables[name.to_s]
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
