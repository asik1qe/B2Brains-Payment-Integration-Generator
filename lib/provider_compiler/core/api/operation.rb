# frozen_string_literal: true

require_relative "parameter"
require_relative "request_body"
require_relative "response"

module ProviderCompiler
  module Core
    module API
      class Operation
        ATTRIBUTES = %i[
          http_method path operation_id tags summary description parameters request_body
          responses security servers server_source deprecated extensions
        ].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          http_method:,
          path:,
          operation_id: nil,
          tags: [],
          summary: nil,
          description: nil,
          parameters: [],
          request_body: nil,
          responses: {},
          security: nil,
          servers: [],
          server_source: nil,
          deprecated: false,
          extensions: {}
        )
          raise ArgumentError, "http_method must not be empty" if empty?(http_method)
          raise ArgumentError, "path must not be empty" if empty?(path)

          @http_method = http_method.to_s.upcase
          @path = path
          @operation_id = operation_id
          @tags = tags.dup
          @summary = summary
          @description = description
          @parameters = parameters.dup
          @request_body = request_body
          @responses = string_keyed_copy(responses)
          @security = security.nil? ? nil : copy_collection(security)
          @servers = servers.dup
          @server_source = server_source&.to_s
          @deprecated = deprecated
          @extensions = string_keyed_copy(extensions)
        end

        def response(status_code)
          responses[status_code.to_s]
        end

        def parameter(name, location: nil)
          parameters.find do |candidate|
            candidate.name.to_s == name.to_s &&
              (location.nil? || candidate.location.to_s.casecmp?(location.to_s))
          end
        end

        def success_responses
          responses.select { |status_code, _| status_code.match?(/\A2\d{2}\z/) }
        end

        def inherits_global_security? = security.nil?
        def security_disabled? = security == []

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
