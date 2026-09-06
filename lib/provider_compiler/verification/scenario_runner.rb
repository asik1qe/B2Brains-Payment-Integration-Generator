# frozen_string_literal: true

require "json"
require_relative "../core/diagnostic"
require_relative "../core/result"
require_relative "../core/space_payments_contract"
require_relative "../core/nested_path"
require_relative "runtime"

module ProviderCompiler
  module Verification
    class ScenarioRunner
      SCENARIOS = %w[
        check_conditions create_request create_request_card
        idempotency identifier_type_coercion
        fetch_status_approved fetch_status_rejected fetch_status_in_progress
        callback_approved callback_rejected callback_in_progress
        bad_request unauthorized rate_limit validation_error provider_error webhook_signature
      ].freeze

      def initialize(runtime: Runtime.new)
        @runtime = runtime
      end

      def call(generated_integration:, mapping_plan:, provider_spec: nil)
        report = SCENARIOS.to_h { |name| [name, "skipped"] }
        diagnostics = []
        loaded = @runtime.load(generated_integration)
        return ProviderCompiler::Core::Result.failure(report, diagnostics: loaded.diagnostics) if loaded.failure?

        fixtures = JSON.parse(generated_integration.fixtures_json)
        context = loaded.value
        operation = build_operation(fixtures, mapping_plan, include_provider_key: false)

        run(report, diagnostics, "check_conditions") do
          outcome = context["service"].check_conditions(operation, "create")
          assert(outcome.is_a?(Hash) && outcome.key?("success"), :scenario_runtime_error,
                 "check_conditions did not return a fake BaseService outcome")
        end

        run_create(report, diagnostics, context, operation, fixtures, mapping_plan)
        run_card_create(report, diagnostics, context, fixtures, mapping_plan)
        run_idempotency(report, diagnostics, context, fixtures, mapping_plan)
        run_identifier_type_coercion(report, diagnostics, context, fixtures, mapping_plan)
        ProviderCompiler::Core::SpacePaymentsContract::INTERNAL_STATUSES.each do |status|
          run_fetch(report, diagnostics, context, fixtures, mapping_plan, status)
          run_callback(report, diagnostics, context, fixtures, mapping_plan, status)
        end
        run_platform_error(report, diagnostics, context, fixtures, mapping_plan, "bad_request", "bad_request")
        run_platform_error(report, diagnostics, context, fixtures, mapping_plan, "unauthorized", "unauthorized")
        run_platform_error(report, diagnostics, context, fixtures, mapping_plan, "rate_limit", "too_many_requests")
        run_platform_error(report, diagnostics, context, fixtures, mapping_plan, "validation_error", "unprocessable_entity")
        run_platform_error(report, diagnostics, context, fixtures, mapping_plan, "provider_error", "internal_server_error")
        record_webhook_limitation(report, diagnostics, mapping_plan)

        if diagnostics.any?(&:blocking?)
          ProviderCompiler::Core::Result.failure(report, diagnostics: diagnostics)
        else
          ProviderCompiler::Core::Result.success(report, diagnostics: diagnostics)
        end
      rescue JSON::ParserError, StandardError => error
        item = diagnostic(
          :scenario_runtime_error,
          "Scenario runner failed: #{error.class}: #{error.message}",
          metadata: { "exception_class" => error.class.name }
        )
        ProviderCompiler::Core::Result.failure(report || skipped_report, diagnostics: [item])
      end

      private

      def run_create(report, diagnostics, context, operation, fixtures, plan, scenario: "create_request", fixture: nil)
        mapping = plan.operation("create_request")
        fixture ||= fixtures["create_request"]
        return unless mapping && fixture.is_a?(Hash)

        run(report, diagnostics, scenario) do
          reset(context)
          original_provider_key = operation.provider_operation_key
          response_status = success_status(mapping.operation)
          context["client"].enqueue_response(
            @runtime.build_response(
              status: response_status,
              body: fixture["provider_response"] || fixtures.dig("create_request", "provider_response") || {}
            )
          )
          outcome = context["service"].create_request(operation, "create")
          call = single_call(context)
          compare_http(call, mapping, operation, plan, context)
          compare_mapped_parameters(call, plan, "create_request", operation)
          compare_body(call, fixture["provider_request"] || {}, plan)
          compare_security(call, plan.security, context["credentials"])
          compare_request_headers(call, plan, operation)
          assert(outcome.is_a?(Hash) && outcome["success"] == true,
                 :scenario_status_outcome_mismatch, "create_request did not return success")
          compare_provider_operation_key(outcome, operation, original_provider_key, fixture, fixtures, plan)
        end
      end

      def run_card_create(report, diagnostics, context, fixtures, plan)
        fixture = fixtures.dig("create_request", "variants", "card")
        return unless fixture.is_a?(Hash)

        operation = @runtime.build_operation(**deep_copy(fixture["operation"] || {}).transform_keys(&:to_sym))
        run_create(
          report,
          diagnostics,
          context,
          operation,
          fixtures,
          plan,
          scenario: "create_request_card",
          fixture: fixture
        )
      end

      def run_idempotency(report, diagnostics, context, fixtures, plan)
        mappings = request_header_mappings(plan)
        mapping = plan.operation("create_request")
        return if mappings.empty? || !mapping

        run(report, diagnostics, "idempotency") do
          reset(context)
          operation = build_operation(fixtures, plan, include_provider_key: false)
          response = fixture_success_response(fixtures, mapping)
          2.times do
            context["client"].enqueue_response(response)
            context["service"].create_request(operation, "create")
          end
          assert(context["client"].calls.size == 2, :scenario_idempotency_mismatch,
                 "Idempotency retry did not produce two requests")
          mappings.each do |header|
            values = context["client"].calls.map { |call| header_value(call, header["provider_name"]) }
            expected = operation.id.to_s
            assert(values == [expected, expected], :scenario_idempotency_mismatch,
                   "Idempotency header #{header['provider_name']} is missing, unstable, or incorrect")
          end
        end
      end

      def run_identifier_type_coercion(report, diagnostics, context, fixtures, plan)
        field = plan.fields.find do |mapping|
          metadata = mapping.metadata
          mapping.request? && mapping.internal_path.to_s == "operation.id" &&
            (metadata["operation_role"] || metadata[:operation_role]).to_s == "create_request" &&
            stringify(mapping.transformation || {})["type"].to_s == "type_cast" &&
            stringify(mapping.transformation || {})["to"].to_s == "string"
        end
        mapping = plan.operation("create_request")
        return unless field && mapping

        run(report, diagnostics, "identifier_type_coercion") do
          reset(context)
          operation = build_operation(fixtures, plan, include_provider_key: false)
          operation.id = 12_345
          condition = context["service"].check_conditions(operation, "create")
          assert(condition.is_a?(Hash) && condition["success"] == true,
                 :scenario_type_coercion_mismatch,
                 "Integer operation.id failed check_conditions for a provider string identifier")
          context["client"].enqueue_response(fixture_success_response(fixtures, mapping))
          outcome = context["service"].create_request(operation, "create")
          call = single_call(context)
          actual = dig_value(call.dig("kwargs", :body), field.provider_path)
          assert(actual == operation.id.to_s,
                 :scenario_type_coercion_mismatch,
                 "Mapped provider string identifier was not coerced with to_s")
          assert(outcome.is_a?(Hash) && outcome["success"] == true,
                 :scenario_type_coercion_mismatch,
                 "create_request failed after identifier type coercion")
        end
      end

      def fixture_success_response(fixtures, mapping)
        @runtime.build_response(
          status: success_status(mapping.operation),
          body: fixtures.dig("create_request", "provider_response") || {}
        )
      end

      def run_fetch(report, diagnostics, context, fixtures, plan, internal_status)
        scenario = "fetch_status_#{internal_status}"
        mapping = plan.operation("fetch_status")
        provider_status = provider_status_for(plan, internal_status)
        return unless mapping && provider_status

        run(report, diagnostics, scenario) do
          reset(context)
          operation = build_operation(fixtures, plan, include_provider_key: true)
          body = deep_copy(fixtures.dig("fetch_status", "provider_response") || {})
          set_path(body, status_path(plan, "fetch_status"), provider_status)
          context["client"].enqueue_response(
            @runtime.build_response(status: success_status(mapping.operation), body: body)
          )
          outcome = context["service"].fetch_status(operation)
          call = single_call(context)
          compare_http(call, mapping, operation, plan, context)
          compare_mapped_parameters(call, plan, "fetch_status", operation)
          compare_security(call, plan.security, context["credentials"])
          compare_status_outcome(context, outcome, internal_status, :scenario_status_outcome_mismatch)
        end
      end

      def run_callback(report, diagnostics, context, fixtures, plan, internal_status)
        scenario = "callback_#{internal_status}"
        payload = fixtures.dig("callbacks", internal_status)
        return unless plan.webhook && payload.is_a?(Hash)

        run(report, diagnostics, scenario) do
          reset(context)
          outcome = context["service"].process_callback(deep_copy(payload))
          compare_status_outcome(context, outcome, internal_status, :scenario_callback_outcome_mismatch)
        end
      end

      def run_platform_error(report, diagnostics, context, fixtures, plan, scenario, target)
        mapping = plan.errors.find { |item| item.target.to_s == target }
        return unless mapping

        run(report, diagnostics, scenario) do
          reset(context)
          fixture = error_fixture(fixtures, mapping.http_status)
          response = @runtime.build_response(
            status: mapping.http_status.to_i,
            body: fixture&.fetch("body", {}) || {},
            headers: fixture&.fetch("headers", {}) || {}
          )
          context["client"].enqueue_response(response)
          outcome = invoke_error_role(context, plan, mapping.operation_role, fixtures)
          assert(outcome.is_a?(Hash) && outcome["success"] == false && outcome["code"].to_s == target,
                 :scenario_error_mapping_mismatch,
                 "HTTP #{mapping.http_status} did not return platform failure #{target}")
        end
      end

      def invoke_error_role(context, plan, role, fixtures)
        operation = build_operation(fixtures, plan, include_provider_key: role.to_s == "fetch_status")
        case role.to_s
        when "create_request" then context["service"].create_request(operation, "create")
        when "fetch_status" then context["service"].fetch_status(operation)
        else
          raise ScenarioMismatch.new(:scenario_error_mapping_mismatch,
                                     "Error mapping has unsupported operation role #{role}")
        end
      end

      def record_webhook_limitation(report, diagnostics, plan)
        return unless plan.webhook&.signed?

        report["webhook_signature"] = "skipped"
        diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: :warning,
          code: :webhook_signature_runtime_unavailable,
          message: "Webhook signature verification requires an unavailable host raw-body/header contract",
          stage: :verification,
          state: :needs_review
        )
      end

      def run(report, diagnostics, name)
        yield
        report[name] = "passed"
      rescue ScenarioMismatch => error
        report[name] = "failed"
        diagnostics << diagnostic(error.code, error.message, location: name)
      rescue StandardError => error
        report[name] = "failed"
        diagnostics << diagnostic(
          :scenario_runtime_error,
          "#{name} crashed: #{error.class}: #{error.message}",
          location: name,
          metadata: { "exception_class" => error.class.name }
        )
      end

      def build_operation(fixtures, plan, include_provider_key:)
        values = deep_copy(fixtures.dig("create_request", "operation") || {})
        response_mapping = plan.fields.find do |field|
          field.response? && field.internal_path.to_s == "operation.provider_operation_key"
        end
        if include_provider_key && response_mapping
          provider_id = dig_value(fixtures.dig("create_request", "provider_response"), response_mapping.provider_path)
          values["provider_operation_key"] ||= provider_id
        end
        @runtime.build_operation(**values.transform_keys(&:to_sym))
      end

      def single_call(context)
        calls = context["client"].calls
        assert(calls.size == 1, :scenario_runtime_error, "Expected exactly one HTTP call, got #{calls.size}")
        calls.first
      end

      def compare_http(call, mapping, operation, plan, context)
        expected_method = mapping.operation.http_method.to_s.upcase
        assert(call["method"] == expected_method, :scenario_http_method_mismatch,
               "Expected #{expected_method}, got #{call["method"]}")
        expected_path = expand_path(mapping.operation.path, operation, mapping.role, plan)
        expected_path = join_base_url(plan, expected_path, context)
        assert(call["path"] == expected_path, :scenario_http_path_mismatch,
               "Expected #{expected_path}, got #{call["path"]}")
      end

      def compare_mapped_parameters(call, plan, role, operation)
        mapped_parameter_fields(plan, role).each do |field|
          location = (field.metadata["location"] || field.metadata[:location]).to_s.downcase
          next if location == "path"

          expected = transformed_expected_value(read_internal(operation, field.internal_path), field.transformation)
          actual = case location
                   when "query" then hash_value(call.dig("kwargs", :query), field.provider_path)
                   when "header" then header_value(call, field.provider_path)
                   when "cookie"
                     cookie_value(call, field.provider_path)
                   end
          assert(actual == expected,
                 :scenario_parameter_mapping_mismatch,
                 "Mapped #{location} parameter #{field.provider_path} is missing or incorrect")
        end

        request_parameter_constants(plan, role).each do |mapping|
          expected = mapping["value"]
          actual = case mapping["location"].to_s.downcase
                   when "query" then hash_value(call.dig("kwargs", :query), mapping["provider_name"])
                   when "header" then header_value(call, mapping["provider_name"])
                   when "cookie" then cookie_value(call, mapping["provider_name"])
                   end
          assert(actual == expected,
                 :scenario_parameter_constant_mismatch,
                 "Constant #{mapping['location']} parameter #{mapping['provider_name']} is missing or incorrect")
        end
      end

      def request_parameter_constants(plan, role)
        Array(plan.metadata["request_parameter_constants"] || plan.metadata[:request_parameter_constants]).map do |item|
          stringify(item)
        end.select { |mapping| mapping["operation_role"].to_s == role.to_s }
      end

      def mapped_parameter_fields(plan, role)
        plan.fields.select do |field|
          metadata = field.metadata
          field.request? &&
            (metadata["operation_role"] || metadata[:operation_role]).to_s == role.to_s &&
            (metadata["source"] || metadata[:source]).to_s == "parameter"
        end
      end

      def transformed_expected_value(value, descriptor)
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
          else value
          end
        else
          value
        end
      end

      def join_base_url(plan, path, context = nil)
        runtime_base = if context && context["service_class"]&.const_defined?(:BASE_URL, false)
                         context["service_class"].const_get(:BASE_URL, false)
                       end
        base = (runtime_base || plan.metadata["base_url"] || plan.metadata[:base_url]).to_s.sub(%r{/+\z}, "")
        return path.to_s if base.empty?

        suffix = path.to_s.sub(%r{\A/+}, "")
        suffix.empty? ? base : "#{base}/#{suffix}"
      end

      def compare_body(call, expected_body, plan)
        actual = call.dig("kwargs", :body)
        assert(hash_contains?(actual, expected_body), :scenario_request_body_mismatch,
               "Mapped request body does not match fixtures")
      end

      def compare_security(call, security, credentials)
        return unless security

        expected = credential_value(credentials, security)
        case
        when security.api_key? && security.header?
          actual = header_value(call, security.name)
        when security.api_key? && security.query?
          actual = hash_value(call.dig("kwargs", :query), security.name)
        when security.api_key? && security.cookie?
          actual = cookie_value(call, security.name)
        when security.bearer?
          actual = header_value(call, security.name)
          expected = [security.prefix, expected].join(" ")
        when security.basic?
          actual = header_value(call, security.name)
          username = read_value(credentials, security.parameters["username_path"])
          password = read_value(credentials, security.parameters["password_path"])
          expected = "Basic #{["#{username}:#{password}"].pack("m0")}"
        else
          return
        end
        assert(actual == expected, :scenario_security_mismatch,
               "Mapped security value #{security.name} is missing or incorrect")
      end

      def compare_request_headers(call, plan, operation)
        request_header_mappings(plan).each do |mapping|
          actual = header_value(call, mapping["provider_name"])
          expected = operation.id.to_s
          assert(actual == expected, :scenario_idempotency_mismatch,
                 "Mapped request header #{mapping['provider_name']} is missing or incorrect")
        end
      end

      def request_header_mappings(plan)
        Array(plan.metadata["request_headers"] || plan.metadata[:request_headers]).map do |mapping|
          mapping.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        end.select do |mapping|
          mapping["operation_role"] == "create_request" && mapping["source"] == "operation.id"
        end
      end

      def compare_provider_operation_key(outcome, operation, original_provider_key, fixture, fixtures, plan)
        mapping = plan.fields.find do |field|
          field.response? && field.internal_path.to_s == "operation.provider_operation_key"
        end
        return unless mapping

        response = fixture["provider_response"] || fixtures.dig("create_request", "provider_response") || {}
        expected = dig_value(response, mapping.provider_path)
        returned = hash_value(outcome["result"], :id)
        assert(returned == expected,
               :scenario_status_outcome_mismatch,
               "create_request did not return result.id")
        assert(operation.provider_operation_key == original_provider_key,
               :scenario_status_outcome_mismatch,
               "create_request mutated operation.provider_operation_key")
      end

      def compare_status_outcome(context, outcome, status, code)
        actions = context["service"].actions
        case status
        when "approved"
          assert(actions.last&.fetch("type", nil) == "approve", code, "Approved status did not approve")
        when "rejected"
          assert(actions.last&.fetch("type", nil) == "reject", code, "Rejected status did not reject")
        else
          assert(actions.empty? && outcome.is_a?(Hash) && outcome["success"] == true,
                 code, "In-progress status produced a terminal or failing outcome")
        end
      end

      def expand_path(template, operation, role, plan)
        template.to_s.gsub(/\{([^}]+)\}/) do
          provider_name = Regexp.last_match(1)
          field = plan.fields.find do |item|
            metadata = item.metadata
            item.provider_path.to_s == provider_name &&
              (metadata["operation_role"] || metadata[:operation_role]).to_s == role.to_s &&
              (metadata["source"] || metadata[:source]).to_s == "parameter"
          end
          field ? read_internal(operation, field.internal_path).to_s : ""
        end
      end

      def request_fields(plan)
        plan.fields.select do |field|
          metadata = field.metadata
          field.request? &&
            (metadata["operation_role"] || metadata[:operation_role]).to_s == "create_request" &&
            (metadata["source"] || metadata[:source]).to_s == "request_body"
        end
      end

      def status_path(plan, role = nil)
        plan.statuses&.provider_path(role) || plan.webhook&.status_path
      end

      def provider_status_for(plan, internal)
        plan.statuses&.mappings&.find { |_provider, target| target.to_s == internal }&.first
      end

      def success_status(operation)
        operation.success_responses.keys.map(&:to_i).find { |status| status.between?(200, 299) } || 200
      end

      def error_fixture(fixtures, status)
        fixtures.fetch("errors", {}).values.find do |fixture|
          fixture.is_a?(Hash) && fixture["http_status"].to_s == status.to_s
        end
      end

      def reset(context)
        context["client"].reset!
        context["service"].reset_actions!
      end

      def read_internal(operation, path)
        path.to_s.delete_prefix("operation.").split(".").reduce(operation) { |value, key| read_value(value, key) }
      end

      def credential_value(credentials, security)
        read_value(credentials, security.credential_path)
      end

      def cookie_value(call, name)
        header_value(call, "Cookie").to_s.split(";").map(&:strip).each do |part|
          key, value = part.split("=", 2)
          return value if key.to_s == name.to_s
        end
        nil
      end

      def header_value(call, name)
        headers = call.dig("kwargs", :headers) || {}
        pair = headers.find { |key, _| key.to_s.casecmp?(name.to_s) }
        pair&.last
      end

      def hash_value(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_sym]
      end

      def read_value(value, key)
        return nil if value.nil? || key.nil?
        return hash_value(value, key) if value.is_a?(Hash)

        value.public_send(key) if value.respond_to?(key)
      end

      def dig_value(value, path)
        return value if path.nil? || path.empty?

        ProviderCompiler::Core::NestedPath.fetch(value, path)
      end

      def set_path(hash, path, value)
        ProviderCompiler::Core::NestedPath.put(hash, path, value)
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
        when Hash then value.to_h { |key, item| [key, deep_copy(item)] }
        when Array then value.map { |item| deep_copy(item) }
        else value
        end
      end

      def hash_contains?(actual, expected)
        return actual == expected unless expected.is_a?(Hash)
        return false unless actual.is_a?(Hash)

        expected.all? do |key, value|
          observed = hash_value(actual, key)
          value.is_a?(Hash) ? hash_contains?(observed, value) : observed == value
        end
      end

      def assert(condition, code, message)
        raise ScenarioMismatch.new(code, message) unless condition
      end

      def skipped_report
        SCENARIOS.to_h { |name| [name, "skipped"] }
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

      class ScenarioMismatch < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end
    end
  end
end
