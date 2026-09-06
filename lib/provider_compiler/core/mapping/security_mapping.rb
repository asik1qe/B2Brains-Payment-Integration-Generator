# frozen_string_literal: true

module ProviderCompiler
  module Core
    module Mapping
      class SecurityMapping
        ATTRIBUTES = %i[
          scheme_key type location name credential_path prefix parameters decision evidence metadata
        ].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          type:,
          scheme_key: nil,
          location: nil,
          name: nil,
          credential_path: nil,
          prefix: nil,
          parameters: {},
          decision: :auto,
          evidence: [],
          metadata: {}
        )
          raise ArgumentError, "type must not be empty" if empty?(type)

          @scheme_key = scheme_key
          @type = type
          @location = location
          @name = name
          @credential_path = credential_path
          @prefix = prefix
          @parameters = string_keyed_copy(parameters)
          @decision = decision.to_s.downcase
          @evidence = copy_collection(evidence)
          @metadata = copy_collection(metadata)
        end

        def api_key? = type.to_s.casecmp?("apiKey")
        def bearer? = type.to_s.casecmp?("bearer")
        def basic? = type.to_s.casecmp?("basic")
        def header? = location.to_s.casecmp?("header")
        def query? = location.to_s.casecmp?("query")
        def cookie? = location.to_s.casecmp?("cookie")
        def auto? = decision == "auto"
        def needs_review? = decision == "needs_review"
        def manual? = decision == "manual"
        def unresolved? = decision == "unresolved"
        def resolved? = !unresolved?

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
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end

        def string_keyed_copy(hash)
          hash.each_with_object({}) do |(key, value), result|
            result[key.to_s] = copy_collection(value)
          end
        end

        def copy_collection(value)
          case value
          when Array
            value.map { |item| copy_collection(item) }
          when Hash
            value.each_with_object({}) { |(key, item), result| result[key] = copy_collection(item) }
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
            serializable_core_object?(value) ? value.to_h : value
          end
        end

        def serializable_core_object?(value)
          class_name = value.class.name.to_s
          value.respond_to?(:to_h) &&
            (class_name.start_with?("ProviderCompiler::Core::API::") ||
             class_name.start_with?("ProviderCompiler::Core::Mapping::"))
        end
      end
    end
  end
end
