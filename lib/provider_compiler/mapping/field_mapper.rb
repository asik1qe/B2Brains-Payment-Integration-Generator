# frozen_string_literal: true

require_relative "field_rules"
require_relative "transformations/money"
require_relative "transformations/type_cast"
require_relative "../core/diagnostic"
require_relative "../core/mapping/field_mapping"

module ProviderCompiler
  module Mapping
    class FieldMapper
      AUTO_THRESHOLD = 50
      REVIEW_THRESHOLD = 30
      AUTO_MARGIN = 10

      KNOWN_REQUISITE_FIELDS = {
        "phone" => ["operation.payout_requisite.sbp.phone", "sbp"],
        "bank_code" => ["operation.payout_requisite.sbp.bank_code", "sbp"],
        "bank_name" => ["operation.payout_requisite.sbp.bank_name", "sbp"],
        "card_number" => ["operation.payout_requisite.card_number", "card"]
      }.freeze

      attr_reader :diagnostics, :request_variants, :unknown_requisites

      def initialize(rules: FieldRules.new)
        @rules = rules
        @diagnostics = []
        @request_variants = []
        @unknown_requisites = []
      end

      def call(provider_spec:, operation_matches:)
        @diagnostics = []
        @request_variants = []
        @unknown_requisites = []
        mappings = []
        create = selected_operation(operation_matches, "create_request")
        fetch = selected_operation(operation_matches, "fetch_status")

        if create
          request_candidates = schema_candidates(create.request_body&.schema, source: "request_body")
          parameter_candidates = operation_parameter_candidates(create)
          mappings.concat(map_create_request_fields(request_candidates, parameter_candidates))
          mappings.concat(map_create_response_id(create))
        else
          %w[operation.amount operation.id operation.payout_requisite operation.provider_operation_key].each do |path|
            unresolved(path, "create_request")
          end
        end

        mappings.concat(map_fetch_parameter(fetch)) if fetch
        mappings
      end

      private

      def map_create_request_fields(body_candidates, parameter_candidates)
        scalar_candidates = body_candidates + parameter_candidates
        fields = %w[operation.amount operation.id].filter_map do |internal_path|
          build_mapping(internal_path, scalar_candidates, direction: "request", role: "create_request")
        end
        requisite = build_mapping(
          "operation.payout_requisite",
          body_candidates,
          direction: "request",
          role: "create_request"
        )
        return fields unless requisite

        nested = known_requisite_mappings(requisite, body_candidates)
        unknown = unknown_requisite_fields(requisite, body_candidates, nested)
        record_unknown_requisites(unknown) unless unknown.empty?

        if nested.empty?
          fields << requisite if unknown.empty?
        else
          @request_variants = build_request_variants(requisite, body_candidates, nested)
          fields.concat(nested)
        end
        fields
      end

      def operation_parameter_candidates(operation)
        operation.parameters.map do |parameter|
          {
            path: parameter.name,
            schema: parameter.schema,
            source: "parameter",
            location: parameter.location,
            required: parameter.required,
            description: parameter.description
          }
        end
      end

      def map_create_response_id(operation)
        candidates = operation.success_responses.values.flat_map do |response|
          schema_candidates(response.schema, source: "response", metadata: { "http_status" => response.status_code })
        end
        mapping = build_mapping(
          "operation.provider_operation_key",
          candidates,
          direction: "response",
          role: "create_request"
        )
        mapping ? [mapping] : []
      end

      def map_fetch_parameter(operation)
        candidates = operation.parameters.map do |parameter|
          {
            path: parameter.name,
            schema: parameter.schema,
            source: "parameter",
            location: parameter.location,
            required: parameter.required,
            description: parameter.description
          }
        end
        mapping = build_mapping(
          "operation.provider_operation_key",
          candidates,
          direction: "request",
          role: "fetch_status"
        )
        mapping ? [mapping] : []
      end

      def build_mapping(internal_path, candidates, direction:, role:)
        ranked = candidates.map do |candidate|
          assessment = @rules.score(candidate, internal_path)
          candidate.merge(score: assessment[:score], evidence: assessment[:evidence])
        end.sort_by { |candidate| [-candidate[:score], candidate[:path].to_s] }
        best = ranked.first

        if best.nil? || best[:score] < REVIEW_THRESHOLD
          unresolved(internal_path, role)
          return nil
        end

        margin = best[:score] - (ranked[1]&.fetch(:score, 0) || 0)
        decision = best[:score] >= AUTO_THRESHOLD && margin >= AUTO_MARGIN ? :auto : :needs_review
        needs_review(internal_path, role, best, margin) if decision == :needs_review

        ProviderCompiler::Core::Mapping::FieldMapping.new(
          internal_path: internal_path,
          provider_path: best[:path],
          direction: direction,
          transformation: field_transformation(internal_path, best),
          required: best[:required] || false,
          decision: decision,
          score: best[:score],
          evidence: best[:evidence],
          metadata: {
            "operation_role" => role,
            "source" => best[:source],
            "location" => best[:location],
            "alternatives" => ranked.drop(1).map { |item| { "path" => item[:path], "score" => item[:score] } }
          }.compact
        )
      end

      def field_transformation(internal_path, candidate)
        money = money_transformation(internal_path, candidate)
        return money if money

        Transformations::TypeCast.infer(internal_path: internal_path, schema: candidate[:schema])
      end

      def money_transformation(internal_path, candidate)
        return unless internal_path == "operation.amount"

        unit = Transformations::Money.infer_unit(candidate[:schema])
        return if unit.nil?

        add_diagnostic(
          :warning,
          :money_unit_needs_review,
          "Money unit was inferred from schema text and requires confirmation",
          state: :needs_review,
          location: internal_path,
          metadata: { "provider_path" => candidate[:path], "unit" => unit }
        )
        descriptor = Transformations::Money.descriptor(unit: unit)
        unless descriptor["factor"].is_a?(Integer)
          add_diagnostic(
            :error,
            :transformation_incomplete,
            "Money transformation requires an integer factor",
            state: :unresolved,
            location: internal_path,
            metadata: {
              "provider_path" => candidate[:path],
              "unit" => unit,
              "transformation" => descriptor
            }
          )
        end
        descriptor
      end

      def known_requisite_mappings(requisite, candidates)
        prefix = "#{requisite.provider_path}."
        candidates.filter_map do |candidate|
          next unless candidate[:path].to_s.start_with?(prefix)

          definition = KNOWN_REQUISITE_FIELDS[normalize(candidate[:path].to_s.split(".").last)]
          next unless definition

          internal_path, variant = definition
          ProviderCompiler::Core::Mapping::FieldMapping.new(
            internal_path: internal_path,
            provider_path: candidate[:path],
            direction: "request",
            required: candidate[:required] || false,
            decision: :auto,
            score: 100,
            evidence: [{
              "rule" => "confirmed_payout_requisite_field",
              "provider_path" => candidate[:path],
              "internal_path" => internal_path
            }],
            metadata: {
              "operation_role" => "create_request",
              "source" => "request_body",
              "request_variant" => variant
            }
          )
        end.uniq { |mapping| mapping.internal_path }
      end

      def unknown_requisite_fields(requisite, candidates, known_mappings)
        prefix = "#{requisite.provider_path}."
        known_paths = known_mappings.map(&:provider_path)
        candidates.filter_map do |candidate|
          path = candidate[:path].to_s
          next unless path.start_with?(prefix)
          next if path == "#{requisite.provider_path}.type" || known_paths.include?(path)
          next if known_paths.any? { |known| known.start_with?("#{path}.") }
          next unless candidate[:schema]&.properties&.empty?

          { "provider_path" => path, "required" => candidate[:required] == true }
        end.uniq { |field| field["provider_path"] }.sort_by { |field| field["provider_path"] }
      end

      def record_unknown_requisites(fields)
        @unknown_requisites = (@unknown_requisites + fields).uniq { |field| field["provider_path"] }
        required, optional = fields.partition { |field| field["required"] }
        add_requisite_diagnostic(required, required: true) unless required.empty?
        add_requisite_diagnostic(optional, required: false) unless optional.empty?
      end

      def add_requisite_diagnostic(fields, required:)
        paths = fields.map { |field| field["provider_path"] }
        add_diagnostic(
          required ? :error : :warning,
          required ? :payout_requisite_mapping_unresolved : :payout_requisite_mapping_needs_review,
          required ? "Required provider requisite fields have no confirmed platform mapping" :
            "Optional provider requisite fields are outside the confirmed platform contract",
          state: required ? :unresolved : :needs_review,
          location: paths.first,
          metadata: { "fields" => paths, "provider_paths" => paths, "required" => required, "requisites" => fields }
        )
      end

      def build_request_variants(requisite, candidates, mappings)
        discriminator = candidates.find { |candidate| candidate[:path].to_s == "#{requisite.provider_path}.type" }
        enum = Array(discriminator&.dig(:schema)&.enum).map(&:to_s)
        %w[sbp card].filter_map do |name|
          next unless mappings.any? { |mapping| mapping.metadata["request_variant"] == name }

          constants = {}
          constants["#{requisite.provider_path}.type"] = name if enum.include?(name)
          {
            "name" => name,
            "when" => {
              "path" => name == "sbp" ? "operation.payout_requisite.sbp" : "operation.payout_requisite.card_number",
              "present" => true
            },
            "constants" => constants
          }
        end
      end

      def schema_candidates(schema, source:, prefix: nil, metadata: {})
        return [] unless schema

        schema.properties.flat_map do |name, child|
          path = [prefix, name].compact.join(".")
          candidate = {
            path: path,
            schema: child,
            source: source,
            required: schema.required?(name)
          }.merge(metadata.transform_keys(&:to_sym))
          [candidate] + schema_candidates(child, source: source, prefix: path, metadata: metadata)
        end
      end

      def selected_operation(matches, role)
        match = matches[role] || matches[role.to_sym]
        return match.operation if match.respond_to?(:operation)
        return match.candidate if match.respond_to?(:candidate)

        match
      end

      def unresolved(internal_path, role)
        add_diagnostic(
          :error,
          :field_mapping_unresolved,
          "No reliable provider field found for #{internal_path}",
          state: :unresolved,
          location: internal_path,
          metadata: { "operation_role" => role }
        )
      end

      def needs_review(internal_path, role, candidate, margin)
        add_diagnostic(
          :warning,
          :field_mapping_needs_review,
          "Field mapping for #{internal_path} is ambiguous",
          state: :needs_review,
          location: internal_path,
          metadata: {
            "operation_role" => role,
            "provider_path" => candidate[:path],
            "score" => candidate[:score],
            "margin" => margin
          }
        )
      end

      def add_diagnostic(severity, code, message, state:, location:, metadata: {})
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

      def normalize(value)
        value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase.tr("-. ", "___")
      end
    end
  end
end
