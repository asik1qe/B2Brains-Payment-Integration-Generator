# frozen_string_literal: true

require_relative "operation_mapping"
require_relative "field_mapping"
require_relative "status_mapping"
require_relative "error_mapping"
require_relative "security_mapping"
require_relative "webhook_mapping"

module ProviderCompiler
  module Core
    module Mapping
      class MappingPlan
        ATTRIBUTES = %i[
          provider_name operations fields statuses errors security webhook conditions diagnostics metadata
        ].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(
          provider_name: nil,
          operations: {},
          fields: [],
          statuses: nil,
          errors: [],
          security: nil,
          webhook: nil,
          conditions: [],
          diagnostics: [],
          metadata: {}
        )
          @provider_name = provider_name
          @operations = operations.each_with_object({}) do |(role, mapping), result|
            result[role.to_s] = mapping
          end
          @fields = fields.dup
          @statuses = statuses
          @errors = errors.dup
          @security = security
          @webhook = webhook
          @conditions = copy_collection(conditions)
          @diagnostics = copy_collection(diagnostics)
          @metadata = copy_collection(metadata)
        end

        def operation(role)
          operations[role.to_s]
        end

        def field(internal_path, direction: nil)
          fields.find do |mapping|
            mapping.internal_path == internal_path &&
              (direction.nil? || mapping.direction == direction.to_s.downcase)
          end
        end

        def fields_for(direction)
          normalized_direction = direction.to_s.downcase
          fields.select { |mapping| mapping.direction == normalized_direction }
        end

        def error_mappings_for(operation_role)
          normalized_role = operation_role.to_s
          errors.select do |mapping|
            mapping.operation_role.nil? || mapping.operation_role == normalized_role
          end
        end

        def resolved?
          diagnostics.none? do |diagnostic|
            diagnostic_value(diagnostic, :severity).to_s.casecmp?("error") ||
              diagnostic_value(diagnostic, :state).to_s.casecmp?("unresolved")
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

        def diagnostic_value(diagnostic, attribute)
          if diagnostic.respond_to?(attribute)
            diagnostic.public_send(attribute)
          elsif diagnostic.is_a?(Hash)
            diagnostic.key?(attribute) ? diagnostic[attribute] : diagnostic[attribute.to_s]
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
