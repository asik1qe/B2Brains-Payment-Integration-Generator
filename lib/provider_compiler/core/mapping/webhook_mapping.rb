# frozen_string_literal: true

require_relative "../api/operation"

module ProviderCompiler
  module Core
    module Mapping
      class WebhookMapping
        ATTRIBUTES = %i[
          operation event_path status_path provider_operation_id_path external_id_path error_path
          signature_header signature_algorithm signature_encoding signed_payload secret_credential_path
          events decision evidence metadata
        ].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          operation: nil,
          event_path: nil,
          status_path: nil,
          provider_operation_id_path: nil,
          external_id_path: nil,
          error_path: nil,
          signature_header: nil,
          signature_algorithm: nil,
          signature_encoding: nil,
          signed_payload: nil,
          secret_credential_path: nil,
          events: {},
          decision: :auto,
          evidence: [],
          metadata: {}
        )
          @operation = operation
          @event_path = event_path
          @status_path = status_path
          @provider_operation_id_path = provider_operation_id_path
          @external_id_path = external_id_path
          @error_path = error_path
          @signature_header = signature_header
          @signature_algorithm = signature_algorithm
          @signature_encoding = signature_encoding
          @signed_payload = signed_payload
          @secret_credential_path = secret_credential_path
          @events = string_keyed_copy(events)
          @decision = decision.to_s.downcase
          @evidence = copy_collection(evidence)
          @metadata = copy_collection(metadata)
        end

        def signed?
          present?(signature_header) || present?(signature_algorithm)
        end

        def event_mapping(event)
          events[event.to_s]
        end

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

        def present?(value)
          !value.nil? && (!value.respond_to?(:empty?) || !value.empty?)
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
