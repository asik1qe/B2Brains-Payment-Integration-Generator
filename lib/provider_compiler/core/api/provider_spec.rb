# frozen_string_literal: true

require_relative "operation"
require_relative "schema"
require_relative "security_scheme"
require_relative "server"

module ProviderCompiler
  module Core
    module API
      class ProviderSpec
        ATTRIBUTES = %i[
          openapi_version title description api_version servers operations schemas
          security_schemes global_security tags extensions
        ].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          openapi_version:,
          title: nil,
          description: nil,
          api_version: nil,
          servers: [],
          operations: [],
          schemas: {},
          security_schemes: {},
          global_security: nil,
          tags: [],
          extensions: {}
        )
          raise ArgumentError, "openapi_version must not be empty" if empty?(openapi_version)

          @openapi_version = openapi_version
          @title = title
          @description = description
          @api_version = api_version
          @servers = servers.dup
          @operations = operations.dup
          @schemas = string_keyed_copy(schemas)
          @security_schemes = string_keyed_copy(security_schemes)
          @global_security = global_security.nil? ? nil : copy_collection(global_security)
          @tags = tags.dup
          @extensions = string_keyed_copy(extensions)
        end

        def operation(http_method:, path:)
          operations.find do |candidate|
            candidate.http_method.to_s.casecmp?(http_method.to_s) && candidate.path == path
          end
        end

        def operations_for_path(path)
          operations.select { |candidate| candidate.path == path }
        end

        def schema(name)
          schemas[name.to_s]
        end

        def security_scheme(name)
          security_schemes[name.to_s]
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

        def copy_collection(value)
          case value
          when Array
            value.map { |item| copy_collection(item) }
          when Hash
            value.each_with_object({}) do |(key, item), result|
              result[key.to_s] = copy_collection(item)
            end
          else
            value
          end
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
