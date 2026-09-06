# frozen_string_literal: true

module ProviderCompiler
  module Core
    module Mapping
      class ErrorMapping
        ATTRIBUTES = %i[
          operation_role http_status provider_code provider_code_path message_path target retryable
          retry_after_header decision evidence metadata
        ].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          operation_role: nil,
          http_status: nil,
          provider_code: nil,
          provider_code_path: nil,
          message_path: nil,
          target: nil,
          retryable: false,
          retry_after_header: nil,
          decision: :auto,
          evidence: [],
          metadata: {}
        )
          @operation_role = operation_role&.to_s
          @http_status = http_status&.to_s
          @provider_code = provider_code
          @provider_code_path = provider_code_path
          @message_path = message_path
          @target = target
          @retryable = retryable
          @retry_after_header = retry_after_header
          @decision = decision.to_s.downcase
          @evidence = copy_collection(evidence)
          @metadata = copy_collection(metadata)
        end

        def matches_http_status?(status)
          !http_status.nil? && http_status == status.to_s
        end

        def retryable? = !!retryable
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
          name = value.class.name.to_s
          value.respond_to?(:to_h) &&
            (name.start_with?("ProviderCompiler::Core::API::") ||
             name.start_with?("ProviderCompiler::Core::Mapping::"))
        end
      end
    end
  end
end
