# frozen_string_literal: true

require_relative "../core/diagnostic"
require_relative "../core/mapping/status_mapping"

module ProviderCompiler
  module Mapping
    class StatusMapper
      CANONICAL = {
        "in_progress" => %w[pending processing in_progress in-progress created new queued waiting awaiting],
        "approved" => %w[completed complete success successful succeeded paid settled approved done],
        "rejected" => %w[failed failure rejected declined cancelled canceled error]
      }.freeze

      attr_reader :diagnostics

      def initialize
        @diagnostics = []
      end

      def call(provider_spec:, operation_matches:)
        @diagnostics = []
        observations = status_observations(operation_matches)
        enums = observations.flat_map { |item| item.fetch("values") }.uniq
        provider_paths = provider_paths(observations)

        validate_status_paths(operation_matches, observations)
        if enums.empty?
          add(:error, :status_mapping_unresolved, "No status/state enum was found", :unresolved)
          return ProviderCompiler::Core::Mapping::StatusMapping.new(
            decision: :unresolved,
            metadata: { "provider_paths" => provider_paths }
          )
        end

        mappings = {}
        evidence = []
        unknown = []
        enums.each do |value|
          internal = canonical_status(value)
          if internal
            mappings[value.to_s] = internal
            evidence << {
              "rule" => "canonical_status_alias",
              "provider_status" => value.to_s,
              "internal_status" => internal
            }
          else
            unknown << value.to_s
            add(
              :warning,
              :status_mapping_needs_review,
              "Unknown provider status #{value.inspect}",
              :needs_review,
              metadata: { "provider_status" => value.to_s }
            )
          end
        end

        unresolved_paths = diagnostics.any? { |item| item.code == "status_path_unresolved" && item.blocking? }
        decision = if unresolved_paths
                     :unresolved
                   elsif unknown.empty?
                     :auto
                   else
                     :needs_review
                   end
        ProviderCompiler::Core::Mapping::StatusMapping.new(
          mappings: mappings,
          decision: decision,
          evidence: evidence,
          metadata: {
            "unknown_provider_statuses" => unknown,
            "provider_paths" => provider_paths
          }
        )
      end

      private

      def status_observations(matches)
        %w[create_request fetch_status process_callback].flat_map do |role|
          operation = selected_operation(matches, role)
          next [] unless operation

          schemas = if role == "process_callback"
                      [operation.request_body&.schema]
                    else
                      operation.success_responses.values.map(&:schema)
                    end
          schemas.compact.flat_map do |schema|
            find_status_fields(schema).map do |path, values|
              { "role" => role, "path" => path, "values" => Array(values) }
            end
          end
        end
      end

      def find_status_fields(schema, prefix = nil)
        return [] unless schema

        schema.properties.flat_map do |name, child|
          path = [prefix, name].compact.join(".")
          current = %w[status state].include?(normalize(name)) ? [[path, child.enum]] : []
          current + find_status_fields(child, path)
        end
      end

      def provider_paths(observations)
        observations.group_by { |item| item.fetch("role") }.each_with_object({}) do |(role, items), result|
          paths = items.map { |item| item.fetch("path") }.uniq
          result[role] = paths.first if paths.one?
        end
      end

      def validate_status_paths(matches, observations)
        %w[fetch_status process_callback].each do |role|
          next unless selected_operation(matches, role)

          paths = observations.select { |item| item.fetch("role") == role }.map { |item| item.fetch("path") }.uniq
          if paths.empty?
            add(
              :error,
              :status_path_unresolved,
              "No status/state field was found for #{role}",
              :unresolved,
              metadata: { "operation_role" => role }
            )
          elsif paths.size > 1
            add(
              :error,
              :status_path_unresolved,
              "Multiple status/state fields were found for #{role}",
              :unresolved,
              metadata: { "operation_role" => role, "provider_paths" => paths }
            )
          end
        end
      end

      def selected_operation(matches, role)
        match = matches[role] || matches[role.to_sym]
        return match.operation if match.respond_to?(:operation)
        return match.candidate if match.respond_to?(:candidate)

        match
      end

      def canonical_status(value)
        normalized = normalize(value)
        matches = CANONICAL.filter_map do |internal, aliases|
          internal if aliases.any? do |item|
            candidate = normalize(item)
            normalized == candidate || normalized.end_with?("_#{candidate}")
          end
        end
        matches.one? ? matches.first : nil
      end

      def normalize(value)
        value.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      end

      def add(severity, code, message, state, metadata: {})
        diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: severity,
          code: code,
          message: message,
          stage: :mapping,
          state: state,
          metadata: metadata
        )
      end
    end
  end
end
