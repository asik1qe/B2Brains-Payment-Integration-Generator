# frozen_string_literal: true

require_relative "schema_example_builder"
require_relative "../core/space_payments_contract"
require_relative "../core/nested_path"

module ProviderCompiler
  module Generation
    class FixturesGenerator
      def initialize(example_builder: SchemaExampleBuilder.new)
        @example_builder = example_builder
      end

      def generate(mapping_plan:, provider_spec: nil)
        {
          "create_request" => create_fixture(mapping_plan),
          "fetch_status" => fetch_fixture(mapping_plan),
          "callbacks" => callback_fixtures(mapping_plan),
          "errors" => error_fixtures(mapping_plan)
        }
      end

      private

      def create_fixture(plan)
        mapping = plan.operation("create_request")
        return { "operation" => {}, "provider_request" => {}, "provider_response" => {} } unless mapping

        request_schema = mapping.operation.request_body&.schema
        fields = create_fields(plan)
        variants = request_variants(plan)
        base_fields = fields.reject { |field| request_variant(field) }
        operation = {}
        provider_request = {}
        base_fields.each { |field| apply_fixture_field(field, request_schema, operation, provider_request) }
        apply_parameter_fixture_fields(plan, mapping.operation, operation)
        ensure_metadata_operation_values(plan, operation)
        request_constants(plan).each do |mapping|
          set_path(provider_request, mapping["provider_path"], mapping["value"])
        end

        variant_fixtures = variants.each_with_object({}) do |variant, result|
          variant_operation = deep_copy(operation)
          variant_request = deep_copy(provider_request)
          fields.select { |field| request_variant(field) == variant["name"] }.each do |field|
            apply_fixture_field(field, request_schema, variant_operation, variant_request)
          end
          variant.fetch("constants", {}).each { |path, value| set_path(variant_request, path, value) }
          result[variant["name"]] = {
            "operation" => variant_operation,
            "provider_request" => variant_request
          }
        end
        unless variant_fixtures.empty?
          default = variant_fixtures.values.first
          operation = deep_copy(default["operation"])
          provider_request = deep_copy(default["provider_request"])
        end
        response = mapping.operation.success_responses.values.first
        fixture = {
          "operation" => operation,
          "provider_request" => provider_request,
          "provider_response" => stringify(@example_builder.build(response&.schema) || {})
        }
        fixture["variants"] = variant_fixtures unless variant_fixtures.empty?
        fixture
      end

      def fetch_fixture(plan)
        mapping = plan.operation("fetch_status")
        return { "provider_response" => {} } unless mapping

        response = mapping.operation.success_responses.values.first
        { "provider_response" => stringify(@example_builder.build(response&.schema) || {}) }
      end

      def callback_fixtures(plan)
        webhook = plan.webhook
        return {} unless webhook&.operation&.request_body&.schema

        base = stringify(@example_builder.build(webhook.operation.request_body.schema) || {})
        ProviderCompiler::Core::SpacePaymentsContract::INTERNAL_STATUSES.each_with_object({}) do |internal, result|
          provider_status = plan.statuses&.mappings&.find { |_provider, target| target == internal }&.first
          next unless provider_status

          event = webhook.events.find { |_provider_event, target| target == internal }&.first
          next if webhook.event_path && !event && required_schema_path?(webhook.operation.request_body.schema, webhook.event_path)

          payload = deep_copy(base)
          set_path(payload, webhook.status_path, provider_status) if webhook.status_path
          if webhook.event_path
            event ? set_path(payload, webhook.event_path, event) : delete_path(payload, webhook.event_path)
          end
          result[internal] = payload
        end
      end

      def required_schema_path?(schema, path)
        tokens = path.to_s.split(".")
        leaf = tokens.pop
        parent = tokens.reduce(schema) { |current, token| current&.property(token) }
        parent&.required?(leaf) == true
      end

      def delete_path(hash, path)
        ProviderCompiler::Core::NestedPath.delete(hash, path)
      end

      def error_fixtures(plan)
        plan.errors.each_with_object({}) do |mapping, result|
          key = error_key(mapping.target)
          next if result.key?(key)

          operation = plan.operation(mapping.operation_role)&.operation
          response = operation&.response(mapping.http_status)
          body = stringify(@example_builder.build(response&.schema) || {})
          set_path(body, mapping.provider_code_path, mapping.provider_code) if mapping.provider_code_path && mapping.provider_code
          fixture = { "http_status" => mapping.http_status.to_i, "body" => body }
          if mapping.retry_after_header
            fixture["headers"] = { mapping.retry_after_header => "60" }
          end
          result[key] = fixture
        end
      end

      def create_parameter_fields(plan)
        plan.fields.select do |field|
          metadata = field.metadata
          field.request? &&
            (metadata["source"] || metadata[:source]).to_s == "parameter" &&
            (metadata["operation_role"] || metadata[:operation_role]).to_s == "create_request"
        end
      end

      def apply_parameter_fixture_fields(plan, operation_mapping, operation_fixture)
        create_parameter_fields(plan).each do |field|
          location = field.metadata["location"] || field.metadata[:location]
          parameter = operation_mapping.parameter(field.provider_path, location: location)
          next unless parameter

          provider_value = @example_builder.build(parameter.schema)
          internal_value = inverse_transform(provider_value, field.transformation)
          set_path(operation_fixture, field.internal_path.delete_prefix("operation."), internal_value)
        end
      end

      def ensure_metadata_operation_values(plan, operation_fixture)
        headers = Array(plan.metadata["request_headers"] || plan.metadata[:request_headers]).map { |item| stringify(item) }
        if headers.any? { |mapping| mapping["source"].to_s == "operation.id" }
          current = ProviderCompiler::Core::NestedPath.fetch(operation_fixture, "id")
          set_path(operation_fixture, "id", "operation-1") if current.nil?
        end
      end

      def create_fields(plan)
        plan.fields.select do |field|
          source = field.metadata["source"] || field.metadata[:source]
          role = field.metadata["operation_role"] || field.metadata[:operation_role]
          field.request? && source.to_s == "request_body" && role.to_s == "create_request" &&
            usable_requisite_mapping?(field)
        end
      end

      def usable_requisite_mapping?(field)
        return true unless field.internal_path.to_s.start_with?("operation.payout_requisite")

        field.auto? || field.manual?
      end

      def request_constants(plan)
        Array(plan.metadata["request_constants"] || plan.metadata[:request_constants]).map { |item| stringify(item) }.select do |mapping|
          mapping["operation_role"].to_s == "create_request"
        end
      end

      def request_variants(plan)
        Array(plan.metadata["request_variants"] || plan.metadata[:request_variants]).map { |item| stringify(item) }
      end

      def request_variant(field)
        (field.metadata["request_variant"] || field.metadata[:request_variant])&.to_s
      end

      def apply_fixture_field(field, schema, operation, provider_request)
        provider_value = value_at_schema(schema, field.provider_path)
        internal_value = inverse_transform(provider_value, field.transformation)
        set_path(operation, field.internal_path.delete_prefix("operation."), internal_value)
        set_path(provider_request, field.provider_path, apply_transform(internal_value, field.transformation))
      end

      def value_at_schema(schema, path)
        target = path.to_s.split(".").reduce(schema) { |current, token| current&.property(token) }
        @example_builder.build(target)
      end

      def inverse_transform(value, descriptor)
        descriptor = stringify(descriptor || {})
        return deep_copy(value) unless descriptor["type"] == "money" && descriptor["factor"].is_a?(Integer)
        return value unless value.is_a?(Numeric)

        factor = descriptor["factor"]
        if value.is_a?(Integer)
          quotient, remainder = value.divmod(factor)
          remainder.zero? ? quotient : quotient + 1
        else
          value.to_f / factor
        end
      end

      def apply_transform(value, descriptor)
        descriptor = stringify(descriptor || {})
        case descriptor["type"]
        when "money"
          descriptor["factor"].is_a?(Integer) && value.is_a?(Numeric) ? value * descriptor["factor"] : value
        when "enum"
          stringify(descriptor["mapping"] || {})[value.to_s]
        when "type_cast"
          case descriptor["to"]
          when "string" then value.nil? ? nil : value.to_s
          when "integer" then value.nil? ? nil : Integer(value)
          when "number" then value.nil? ? nil : Float(value)
          else deep_copy(value)
          end
        else
          deep_copy(value)
        end
      end

      def error_key(target)
        case target.to_s
        when "Provider::UnauthorizedError" then "unauthorized"
        when "Provider::RateLimitError" then "rate_limit"
        else target.to_s.gsub(/[^a-zA-Z0-9]+/, "_").downcase.gsub(/\A_|_\z/, "")
        end
      end

      def set_path(hash, path, value)
        ProviderCompiler::Core::NestedPath.put(hash, path, deep_copy(value))
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

      def deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key] = deep_copy(item) }
        when Array
          value.map { |item| deep_copy(item) }
        else
          value
        end
      end
    end
  end
end
