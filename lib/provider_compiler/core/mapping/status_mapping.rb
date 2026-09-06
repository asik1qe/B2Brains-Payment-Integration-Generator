# frozen_string_literal: true

module ProviderCompiler
  module Core
    module Mapping
      class StatusMapping
        ATTRIBUTES = %i[mappings decision evidence unknown_status metadata].freeze

        attr_reader(*ATTRIBUTES)

        def initialize(mappings: {}, decision: :auto, evidence: [], unknown_status: nil, metadata: {})
          @mappings = mappings.each_with_object({}) do |(provider_status, internal_status), result|
            result[provider_status.to_s] = copy_collection(internal_status)
          end
          @decision = decision.to_s.downcase
          @evidence = copy_collection(evidence)
          @unknown_status = unknown_status
          @metadata = copy_collection(metadata)
        end

        def map(provider_status)
          mappings.fetch(provider_status.to_s, unknown_status)
        end

        def mapped?(provider_status)
          mappings.key?(provider_status.to_s)
        end

        def provider_statuses
          mappings.keys
        end

        def provider_path(role = nil)
          paths = metadata["provider_paths"] || metadata[:provider_paths]
          if role && paths.is_a?(Hash)
            return paths[role.to_s] || paths[role.to_sym]
          end

          metadata["provider_path"] || metadata[:provider_path]
        end

        def internal_statuses
          mappings.values.uniq
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
