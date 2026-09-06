# frozen_string_literal: true

require_relative "schema"
require_relative "parameter"

module ProviderCompiler
  module Core
    module API
      class Response
        ATTRIBUTES = %i[status_code description content_type schema headers examples extensions].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          status_code:,
          description: nil,
          content_type: nil,
          schema: nil,
          headers: {},
          examples: {},
          extensions: {}
        )
          @status_code = status_code.to_s
          @description = description
          @content_type = content_type
          @schema = schema
          @headers = string_keyed_copy(headers)
          @examples = string_keyed_copy(examples)
          @extensions = string_keyed_copy(extensions)
        end

        def numeric_status
          status_code.match?(/\A\d+\z/) ? status_code.to_i : nil
        end

        def success? = numeric_status&.between?(200, 299) || false
        def client_error? = numeric_status&.between?(400, 499) || false
        def server_error? = numeric_status&.between?(500, 599) || false

        def header(name)
          requested_name = name.to_s
          pair = headers.find { |header_name, _| header_name.casecmp?(requested_name) }
          pair&.last
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
