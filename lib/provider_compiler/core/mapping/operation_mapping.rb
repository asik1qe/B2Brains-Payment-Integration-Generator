# frozen_string_literal: true

require_relative "../api/operation"

module ProviderCompiler
  module Core
    module Mapping
      class OperationMapping
        ATTRIBUTES = %i[role operation decision score evidence metadata].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(role:, operation:, decision: :auto, score: nil, evidence: [], metadata: {})
          raise ArgumentError, "role must not be empty" if empty?(role)
          raise ArgumentError, "operation must not be empty" if empty?(operation)

          @role = role.to_s
          @operation = operation
          @decision = decision.to_s.downcase
          @score = score
          @evidence = copy_collection(evidence)
          @metadata = copy_collection(metadata)
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

        def empty?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
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
          name = value.class.name.to_s
          value.respond_to?(:to_h) &&
            (name.start_with?("ProviderCompiler::Core::API::") ||
             name.start_with?("ProviderCompiler::Core::Mapping::"))
        end
      end
    end
  end
end
