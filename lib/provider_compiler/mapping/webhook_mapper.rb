# frozen_string_literal: true

require_relative "field_rules"
require_relative "../core/diagnostic"
require_relative "../core/mapping/webhook_mapping"

module ProviderCompiler
  module Mapping
    class WebhookMapper
      FIELD_ALIASES = {
        event_path: %w[event event_type type],
        status_path: %w[status state],
        provider_operation_id_path: FieldRules::PROVIDER_OPERATION_ID_ALIASES,
        external_id_path: %w[external_id merchant_id client_id reference_id],
        error_path: %w[error failure reason]
      }.freeze
      REQUIRED_RUNTIME_PATHS = %i[status_path provider_operation_id_path].freeze

      attr_reader :diagnostics

      def initialize
        @diagnostics = []
      end

      def call(operation_mapping = nil, operation: nil)
        @diagnostics = []
        selected = operation || selected_operation(operation_mapping)
        unless selected
          add(:error, :webhook_mapping_unresolved, "No callback operation was selected", :unresolved)
          return nil
        end

        schema = selected.request_body&.schema
        paths = FIELD_ALIASES.transform_values { |aliases| find_path(schema, aliases) }
        signature = selected.parameters.find { |parameter| parameter.header? && signature_parameter?(parameter) }
        algorithm = infer_algorithm(signature)
        missing_runtime = REQUIRED_RUNTIME_PATHS.select { |key| paths[key].nil? }
        missing_runtime.each do |key|
          add(
            :error,
            :webhook_field_mapping_unresolved,
            "Required callback field #{key} could not be mapped safely",
            :unresolved,
            location: key.to_s,
            metadata: { "field" => key.to_s, "operation_path" => selected.path }
          )
        end

        review_reasons = []
        if signature
          review_reasons << "signature encoding, signed payload, and secret credential are not specified"
        end
        review_reasons.each { |reason| add(:warning, :webhook_mapping_needs_review, reason, :needs_review) }

        decision = if missing_runtime.any?
                     :unresolved
                   elsif review_reasons.empty?
                     :auto
                   else
                     :needs_review
                   end
        event_schema = schema_at(schema, paths[:event_path])
        ProviderCompiler::Core::Mapping::WebhookMapping.new(
          operation: selected,
          **paths,
          signature_header: signature&.name,
          signature_algorithm: algorithm,
          signature_encoding: nil,
          signed_payload: nil,
          secret_credential_path: nil,
          events: event_mappings(event_schema&.enum),
          decision: decision,
          evidence: webhook_evidence(paths, signature, algorithm),
          metadata: { "missing_paths" => missing_runtime.map(&:to_s) }
        )
      end

      private

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

      def signature_parameter?(parameter)
        [parameter.name, parameter.description].compact.join(" ").match?(/signature|\bsign\b|hmac|digest|подпис/i)
      end

      def infer_algorithm(parameter)
        return unless parameter

        text = [parameter.name, parameter.description].compact.join(" ")
        return "HMAC-SHA256" if text.match?(/HMAC[\s_-]*SHA[\s_-]*256/i)
        return "HMAC-SHA512" if text.match?(/HMAC[\s_-]*SHA[\s_-]*512/i)
        return "SHA256" if text.match?(/SHA[\s_-]*256/i)
        return "SHA512" if text.match?(/SHA[\s_-]*512/i)

        nil
      end

      def event_mappings(values)
        Array(values).each_with_object({}) do |value, result|
          normalized = value.to_s.downcase.tr("- ", "__")
          target = if normalized.match?(/completed|success|succeeded|paid|approved|done|settled/)
                     "approved"
                   elsif normalized.match?(/failed|rejected|declined|cancelled|canceled|error/)
                     "rejected"
                   elsif normalized.match?(/pending|processing|queued|waiting|created|new/)
                     "in_progress"
                   end
          result[value.to_s] = target if target
        end
      end

      def webhook_evidence(paths, signature, algorithm)
        paths.filter_map do |key, path|
          { "rule" => "webhook_#{key}", "provider_path" => path } if path
        end.tap do |items|
          items << { "rule" => "signature_header", "name" => signature.name } if signature
          items << { "rule" => "signature_algorithm", "algorithm" => algorithm } if algorithm
        end
      end

      def selected_operation(match)
        return match.operation if match.respond_to?(:operation)
        return match.candidate if match.respond_to?(:candidate)

        match
      end

      def normalize(value)
        value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase.tr("- ", "__")
      end

      def add(severity, code, message, state, location: nil, metadata: {})
        diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: severity,
          code: code,
          message: message,
          stage: :mapping,
          state: state,
          location: location,
          metadata: metadata
        )
      end
    end
  end
end
