# frozen_string_literal: true

require_relative "../core/diagnostic"
require_relative "../core/mapping/security_mapping"

module ProviderCompiler
  module Mapping
    class SecurityMapper
      attr_reader :diagnostics

      def initialize
        @diagnostics = []
      end

      def call(provider_spec:, operation_match: nil, operation_matches: nil)
        @diagnostics = []
        match = operation_match || operation_matches&.fetch("create_request", nil) || operation_matches&.fetch(:create_request, nil)
        operation = selected_operation(match)
        requirements = operation&.security.nil? ? provider_spec.global_security : operation.security
        if operation_matches
          outbound = %w[create_request fetch_status].filter_map do |role|
            selected = selected_operation(operation_matches[role] || operation_matches[role.to_sym])
            next unless selected

            selected.security.nil? ? provider_spec.global_security : selected.security
          end
          if outbound.map { |item| normalized_requirements(item) }.uniq.size > 1
            unresolved("Outbound operations require different security mappings")
          end
        end
        return nil if requirements == []

        groups = Array(requirements).select { |requirement| requirement.is_a?(Hash) }
        keys = groups.flat_map { |requirement| requirement.keys.map(&:to_s) }.uniq
        if keys.empty?
          unresolved("No effective security requirement was found")
          return nil
        end

        schemes = keys.filter_map { |key| provider_spec.security_scheme(key) }
        if schemes.empty?
          unresolved("Referenced security schemes were not found")
          return nil
        end
        if schemes.size != keys.size
          unresolved("One or more referenced security schemes are unsupported or missing")
          return mapping_for(schemes.first, ambiguous: true)
        end
        if groups.any? { |requirement| requirement.keys.size > 1 }
          unresolved("Combined AND security requirements cannot be represented safely")
          return mapping_for(schemes.first, ambiguous: true)
        end

        ambiguous = keys.size != 1 || schemes.size != 1 || Array(requirements).size != 1
        scheme = schemes.first
        mapping = mapping_for(scheme, ambiguous: ambiguous)
        if ambiguous && mapping
          alternatives = schemes.filter_map do |candidate|
            candidate_mapping = mapping_for(candidate, ambiguous: false, report_unsupported: false)
            candidate_mapping&.to_h
          end
          mapping = copy_mapping(mapping, metadata: mapping.metadata.merge("alternatives" => alternatives))
          review("Multiple or ambiguous security requirements", metadata: { "alternatives" => alternatives })
        end
        mapping
      end

      private

      def mapping_for(scheme, ambiguous:, report_unsupported: true)
        decision = ambiguous ? :needs_review : :auto
        common = {
          scheme_key: scheme.key,
          decision: decision,
          evidence: [{ "rule" => "openapi_security_scheme", "scheme_key" => scheme.key, "type" => scheme.type }]
        }
        if scheme.api_key?
          ProviderCompiler::Core::Mapping::SecurityMapping.new(
            **common,
            type: "apiKey",
            location: scheme.location,
            name: scheme.name,
            credential_path: "api_key"
          )
        elsif scheme.bearer?
          ProviderCompiler::Core::Mapping::SecurityMapping.new(
            **common,
            type: "bearer",
            location: "header",
            name: "Authorization",
            credential_path: "token",
            prefix: "Bearer"
          )
        elsif scheme.basic?
          ProviderCompiler::Core::Mapping::SecurityMapping.new(
            **common,
            type: "basic",
            location: "header",
            name: "Authorization",
            parameters: { "username_path" => "username", "password_path" => "password" }
          )
        else
          unresolved("Unsupported security scheme #{scheme.type}") if report_unsupported
          ProviderCompiler::Core::Mapping::SecurityMapping.new(
            **common,
            type: scheme.type,
            location: scheme.location,
            name: scheme.name,
            decision: :unresolved
          )
        end
      end

      def copy_mapping(mapping, metadata: mapping.metadata)
        ProviderCompiler::Core::Mapping::SecurityMapping.new(
          scheme_key: mapping.scheme_key,
          type: mapping.type,
          location: mapping.location,
          name: mapping.name,
          credential_path: mapping.credential_path,
          prefix: mapping.prefix,
          parameters: mapping.parameters,
          decision: mapping.decision,
          evidence: mapping.evidence,
          metadata: metadata
        )
      end

      def selected_operation(match)
        return match.operation if match.respond_to?(:operation)
        return match.candidate if match.respond_to?(:candidate)

        match
      end

      def normalized_requirements(requirements)
        Array(requirements).map do |requirement|
          requirement.is_a?(Hash) ? requirement.keys.map(&:to_s).sort : requirement.to_s
        end
      end

      def unresolved(message)
        diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: :security_mapping_unresolved,
          message: message,
          stage: :mapping,
          state: :unresolved
        )
      end

      def review(message, metadata: {})
        diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: :security_mapping_needs_review,
          message: message,
          stage: :mapping,
          state: :unresolved,
          metadata: metadata
        )
      end
    end
  end
end
