# frozen_string_literal: true

require_relative "../core/diagnostic"
require_relative "../core/space_payments_contract"
require_relative "../core/mapping/error_mapping"

module ProviderCompiler
  module Mapping
    class ErrorMapper
      attr_reader :diagnostics

      def initialize
        @diagnostics = []
      end

      def call(provider_spec:, operation_matches:)
        @diagnostics = []
        operation_matches.each_with_object([]) do |(role, match), mappings|
          operation = selected_operation(match)
          next unless operation

          operation.responses.each_value do |response|
            status = response.numeric_status
            next unless status && status >= 400

            mappings << build_mapping(role.to_s, response)
          end
        end
      end

      private

      def build_mapping(role, response)
        target, decision, rule = target_for(response.numeric_status)
        retry_header = response.headers.keys.find { |name| name.casecmp?("Retry-After") }
        code_path = find_path(response.schema, %w[code error_code])
        message_path = find_path(response.schema, %w[message error_message detail])
        provider_codes = schema_at(response.schema, code_path)&.enum

        if decision == :needs_review
          diagnostics << ProviderCompiler::Core::Diagnostic.new(
            severity: :warning,
            code: :error_mapping_needs_review,
            message: "HTTP #{response.status_code} error mapping requires review",
            stage: :mapping,
            state: :needs_review,
            location: "#{role}:#{response.status_code}"
          )
        end

        ProviderCompiler::Core::Mapping::ErrorMapping.new(
          operation_role: role,
          http_status: response.status_code,
          provider_code_path: code_path,
          message_path: message_path,
          target: target,
          retryable: response.numeric_status == 429 || response.numeric_status.to_i >= 500,
          retry_after_header: retry_header,
          decision: decision,
          evidence: [{ "rule" => rule, "http_status" => response.status_code }],
          metadata: {
            "provider_codes" => provider_codes,
            "provider_code_targets" => provider_code_targets(provider_codes, target),
            "description" => response.description
          }.compact
        )
      end

      def target_for(status)
        case status
        when 400 then ["bad_request", :auto, "http_bad_request"]
        when 401 then ["unauthorized", :auto, "http_unauthorized"]
        when 403 then ["forbidden", :auto, "http_forbidden"]
        when 402, 404, 409, 422 then ["unprocessable_entity", :auto, "http_unprocessable_entity"]
        when 429 then ["too_many_requests", :auto, "http_too_many_requests"]
        when 500..599 then ["internal_server_error", :auto, "http_internal_server_error"]
        else ["internal_server_error", :needs_review, "http_unclassified_error"]
        end
      end

      def provider_code_targets(provider_codes, target)
        Array(provider_codes).to_h { |code| [code.to_s, target] }
      end

      def find_path(schema, aliases, prefix = nil)
        return unless schema

        schema.properties.each do |name, child|
          path = [prefix, name].compact.join(".")
          return path if aliases.include?(normalize(name))

          nested = find_path(child, aliases, path)
          return nested if nested
        end
        nil
      end

      def schema_at(schema, path)
        return unless schema && path

        path.split(".").reduce(schema) { |current, token| current&.property(token) }
      end

      def selected_operation(match)
        return match.operation if match.respond_to?(:operation)
        return match.candidate if match.respond_to?(:candidate)

        match
      end

      def normalize(value)
        value.to_s.downcase.tr("- ", "__")
      end
    end
  end
end
