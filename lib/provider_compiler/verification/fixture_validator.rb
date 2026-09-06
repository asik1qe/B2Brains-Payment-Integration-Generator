# frozen_string_literal: true

require "json"
require_relative "../core/diagnostic"
require_relative "../core/result"
require_relative "../core/space_payments_contract"
require_relative "../core/nested_path"

module ProviderCompiler
  module Verification
    class FixtureValidator
      REQUIRED_SECTIONS = %w[create_request fetch_status callbacks errors].freeze
      SENSITIVE_KEYS = %w[api_key authorization token password secret webhook_secret].freeze
      PLACEHOLDERS = /\A(?:test[-_ ]|example|placeholder|replace|redacted|dummy|your[-_ ])/i

      def call(generated_integration, mapping_plan: nil)
        fixtures = JSON.parse(generated_integration.fixtures_json)
        return failure(:fixtures_root_invalid, "Fixtures root must be an object") unless fixtures.is_a?(Hash)

        diagnostics = structure_diagnostics(fixtures)
        diagnostics.concat(mapping_diagnostics(fixtures, mapping_plan)) if mapping_plan
        diagnostics.concat(secret_diagnostics(fixtures))

        return ProviderCompiler::Core::Result.success(fixtures) if diagnostics.empty?

        ProviderCompiler::Core::Result.failure(fixtures, diagnostics: diagnostics)
      rescue JSON::ParserError => error
        failure(
          :fixtures_json_invalid,
          "Fixtures JSON is invalid",
          metadata: { "exception_class" => error.class.name }
        )
      end

      private

      def structure_diagnostics(fixtures)
        diagnostics = []
        REQUIRED_SECTIONS.each do |section|
          unless fixtures[section].is_a?(Hash)
            diagnostics << diagnostic(
              :fixtures_structure_invalid,
              "Fixtures section #{section} must be an object",
              location: section
            )
          end
        end
        required_nested_sections.each do |path|
          next unless fixtures[path.split(".").first].is_a?(Hash)

          unless dig_value(fixtures, path).is_a?(Hash)
            diagnostics << diagnostic(
              :fixtures_structure_invalid,
              "Fixtures value #{path} must be an object",
              location: path
            )
          end
        end
        diagnostics
      end

      def mapping_diagnostics(fixtures, plan)
        diagnostics = []
        if fixtures["create_request"].is_a?(Hash) && !fixtures["create_request"].empty? && !plan.operation("create_request")
          diagnostics << inconsistent("Create fixture has no create_request mapping", "create_request")
        end
        diagnostics.concat(required_request_diagnostics(fixtures, plan))

        provider_status_locations(fixtures, plan).each do |location, provider_status|
          next if provider_status.nil? || plan.statuses&.mapped?(provider_status)

          diagnostics << inconsistent(
            "Provider status #{provider_status} is absent from StatusMapping",
            location
          )
        end

        callbacks = fixtures["callbacks"]
        if callbacks.is_a?(Hash)
          callbacks.sort.each do |internal, payload|
            next unless ProviderCompiler::Core::SpacePaymentsContract.internal_status?(internal)

            provider_status = dig_value(payload, plan.webhook&.status_path)
            unless plan.statuses && provider_status && plan.statuses.map(provider_status).to_s == internal
              diagnostics << inconsistent(
                "Callback fixture #{internal} is inconsistent with StatusMapping",
                "callbacks.#{internal}"
              )
            end

            provider_event = dig_value(payload, plan.webhook&.event_path)
            next if provider_event.nil?
            next if plan.webhook&.event_mapping(provider_event).to_s == internal

            diagnostics << inconsistent(
              "Callback fixture #{internal} is inconsistent with WebhookMapping events",
              "callbacks.#{internal}"
            )
          end
        end

        errors = fixtures["errors"]
        if errors.is_a?(Hash)
          known = plan.errors.map { |mapping| mapping.http_status.to_s }.uniq
          errors.sort.each do |name, fixture|
            status = fixture.is_a?(Hash) ? fixture["http_status"] : nil
            next if status && known.include?(status.to_s)

            diagnostics << inconsistent(
              "Error fixture #{name} has no matching ErrorMapping",
              "errors.#{name}"
            )
          end
        end
        diagnostics
      end

      def required_request_diagnostics(fixtures, plan)
        schema = plan.operation("create_request")&.operation&.request_body&.schema
        return [] unless schema

        required_paths = required_leaf_paths(schema)
        return [] if required_paths.empty?

        variants = fixtures.dig("create_request", "variants")
        payloads = if variants.is_a?(Hash) && !variants.empty?
                     variants.map do |name, fixture|
                       [name.to_s, fixture.is_a?(Hash) ? fixture["provider_request"] : nil,
                        "create_request.variants.#{name}.provider_request"]
                     end
                   else
                     [[nil, fixtures.dig("create_request", "provider_request"), "create_request.provider_request"]]
                   end

        payloads.flat_map do |variant_name, payload, location|
          next [] unless payload.is_a?(Hash)

          required_paths.filter_map do |path|
            next unless required_path_applicable?(plan, path, variant_name)
            next if nested_path_present?(payload, path)

            diagnostic(
              :fixtures_required_request_field_missing,
              "Generated provider request fixture is missing required OpenAPI field #{path}",
              location: "#{location}.#{path}",
              metadata: { "provider_path" => path, "request_variant" => variant_name }
            )
          end
        end
      end

      def required_leaf_paths(schema, prefix = nil, parent_required = true, result = [])
        schema.properties.each do |name, child|
          path = [prefix, name].compact.join(".")
          required = parent_required && schema.required?(name)
          if child.properties.any?
            required_leaf_paths(child, path, required, result)
          elsif required
            result << path
          end
        end
        result
      end

      def required_path_applicable?(plan, path, variant_name)
        return true if variant_name.nil?

        owners = plan.fields.filter_map do |field|
          next unless field.request?
          metadata = field.metadata
          next unless (metadata["operation_role"] || metadata[:operation_role]).to_s == "create_request"
          next unless (metadata["source"] || metadata[:source]).to_s == "request_body"
          provider_path = field.provider_path.to_s
          next unless path == provider_path || path.start_with?("#{provider_path}.")

          (metadata["request_variant"] || metadata[:request_variant])&.to_s
        end.compact.uniq
        return owners.include?(variant_name.to_s) unless owners.empty?

        constant_owners = Array(plan.metadata["request_variants"] || plan.metadata[:request_variants]).filter_map do |raw|
          variant = stringify(raw)
          constants = stringify(variant["constants"] || {})
          variant["name"].to_s if constants.keys.any? { |candidate| path == candidate || path.start_with?("#{candidate}.") }
        end
        return constant_owners.include?(variant_name.to_s) unless constant_owners.empty?

        true
      end

      def nested_path_present?(value, path)
        keys = ProviderCompiler::Core::NestedPath.segments(path)
        keys.each_with_index.reduce(value) do |current, (key, index)|
          return false unless current.is_a?(Hash)
          actual_key = if current.key?(key)
                         key
                       elsif current.key?(key.to_sym)
                         key.to_sym
                       else
                         return false
                       end
          observed = current[actual_key]
          return true if index == keys.length - 1

          observed
        end
        false
      end

      def stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
        when Array
          value.map { |item| stringify(item) }
        else
          value
        end
      end

      def secret_diagnostics(value, path = [])
        case value
        when Hash
          value.each_with_object([]) do |(key, item), diagnostics|
            current_path = path + [key.to_s]
            if sensitive_key?(key) && secret_value?(item)
              diagnostics << diagnostic(
                :fixture_contains_secret,
                "Fixture contains a credential-like value",
                location: current_path.join(".")
              )
            else
              diagnostics.concat(secret_diagnostics(item, current_path))
            end
          end
        when Array
          value.each_with_index.flat_map { |item, index| secret_diagnostics(item, path + [index.to_s]) }
        else
          []
        end
      end

      def sensitive_key?(key)
        normalized = key.to_s.downcase
        SENSITIVE_KEYS.any? { |candidate| normalized == candidate || normalized.end_with?("_#{candidate}") }
      end

      def required_nested_sections
        %w[
          create_request.operation create_request.provider_request create_request.provider_response
          fetch_status.provider_response
        ]
      end

      def provider_status_locations(fixtures, plan)
        {
          "create_request.provider_response" => plan.statuses&.provider_path("create_request"),
          "fetch_status.provider_response" => plan.statuses&.provider_path("fetch_status")
        }.filter_map do |prefix, path|
          next unless path

          payload = dig_value(fixtures, prefix)
          next unless payload.is_a?(Hash)

          ["#{prefix}.#{path}", dig_value(payload, path)]
        end
      end

      def secret_value?(value)
        value.is_a?(String) && !value.strip.empty? && !value.match?(PLACEHOLDERS)
      end

      def dig_value(value, path)
        return nil unless value.is_a?(Hash) && path && !path.empty?

        ProviderCompiler::Core::NestedPath.fetch(value, path)
      end

      def inconsistent(message, location)
        diagnostic(:fixtures_mapping_inconsistent, message, location: location)
      end

      def failure(code, message, metadata: {})
        item = diagnostic(code, message, metadata: metadata)
        ProviderCompiler::Core::Result.failure(nil, diagnostics: [item])
      end

      def diagnostic(code, message, location: nil, metadata: {})
        ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :verification,
          state: :unresolved,
          location: location,
          metadata: metadata
        )
      end
    end
  end
end
