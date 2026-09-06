# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::Mapper do
  subject(:mapper) { described_class.new }

  def real_provider_spec
    path = SpecPaths.fixture("official", "novapay_provider_api.yaml")
    loaded = ProviderCompiler::OpenAPI::Loader.new.call(path)
    ProviderCompiler::OpenAPI::Parser.new.call(loaded.value).value
  end

  describe "real NovaPay integration" do
    let(:provider_spec) { real_provider_spec }
    let(:result) { mapper.call(provider_spec) }
    let(:plan) { result.value }

    it "maps all operation roles with explainable automatic decisions" do
      expect(result).to be_success
      expect(plan.operations.transform_values { |mapping| [mapping.operation.http_method, mapping.operation.path] }).to eq(
        "create_request" => ["POST", "/payouts"],
        "fetch_status" => ["GET", "/payouts/{payout_id}"],
        "process_callback" => ["POST", "/webhooks/payout"]
      )
      expect(plan.operations.values).to all(be_auto)
      expect(plan.operations.values).to all(satisfy { |mapping| mapping.score >= 55 && mapping.evidence.any? })
    end

    it "maps request, response, and fetch-parameter fields" do
      expect(plan.fields.map { |field| [field.internal_path, field.provider_path, field.direction] }).to include(
        ["operation.amount", "amount", "request"],
        ["operation.id", "external_id", "request"],
        ["operation.payout_requisite.sbp.phone", "recipient.phone", "request"],
        ["operation.payout_requisite.sbp.bank_code", "recipient.bank_code", "request"],
        ["operation.payout_requisite.card_number", "recipient.card_number", "request"],
        ["operation.provider_operation_key", "id", "response"],
        ["operation.provider_operation_key", "payout_id", "request"]
      )
    end

    it "maps statuses, standard errors, and API-key security" do
      expect(plan.statuses.mappings).to eq(
        "pending" => "in_progress",
        "processing" => "in_progress",
        "completed" => "approved",
        "failed" => "rejected",
        "cancelled" => "rejected"
      )
      targets = plan.errors.to_h { |mapping| [[mapping.operation_role, mapping.http_status], mapping.target] }
      expect(targets).to include(
        ["create_request", "400"] => "bad_request",
        ["create_request", "401"] => "unauthorized",
        ["create_request", "422"] => "unprocessable_entity",
        ["create_request", "429"] => "too_many_requests",
        ["create_request", "500"] => "internal_server_error"
      )
      expect(plan.errors.find { |mapping| mapping.http_status == "429" }.retry_after_header).to eq("Retry-After")
      expect(plan.security.to_h).to include(
        type: "apiKey", location: "header", name: "X-API-Key", credential_path: "api_key", decision: "auto"
      )
    end

    it "extracts webhook facts without inventing cryptographic details" do
      expect(plan.webhook.to_h).to include(
        event_path: "event",
        status_path: "status",
        provider_operation_id_path: "payout_id",
        external_id_path: "external_id",
        error_path: "error",
        signature_header: "X-NovaPay-Signature",
        signature_algorithm: "HMAC-SHA256"
      )
      expect(plan.webhook.signature_encoding).to be_nil
      expect(plan.webhook.signed_payload).to be_nil
      expect(plan.webhook.secret_credential_path).to be_nil
    end

    it "collects structured conditions and flags only text-derived ambiguities" do
      expect(plan.conditions).to include(
        a_hash_including("provider_path" => "amount", "kind" => "minimum", "value" => 100_000),
        a_hash_including("provider_path" => "currency", "kind" => "enum", "value" => ["RUB"]),
        a_hash_including("provider_path" => "recipient.phone", "kind" => "pattern", "value" => "^7\\d{10}$"),
        a_hash_including("provider_path" => "external_id", "kind" => "max_length", "value" => 64)
      )
      expect(result.diagnostics.map(&:code)).to contain_exactly(
        "money_unit_needs_review",
        "webhook_mapping_needs_review",
        "conditional_rule_needs_review",
        "conditional_rule_needs_review"
      )
      expect(result.diagnostics).to all(be_needs_review)
    end

    it "applies the general NovaPay override fixture as manual confirmations" do
      path = SpecPaths.fixture("overrides", "novapay_overrides.yml")
      overridden = mapper.call(provider_spec, overrides: path)
      overridden_plan = overridden.value

      expect(overridden).to be_success
      expect(overridden.diagnostics).to be_empty
      expect(overridden_plan.field("operation.amount", direction: :request).transformation).to eq(
        "type" => "money", "unit" => "kopecks", "factor" => 100
      )
      expect(overridden_plan.field("operation.amount", direction: :request)).to be_manual
      expect(overridden_plan.webhook.signature_encoding).to eq("hex")
      expect(overridden_plan.webhook.signed_payload).to eq("raw_body")
      expect(overridden_plan.webhook.secret_credential_path).to eq("webhook_secret")
      expect(overridden_plan.webhook).to be_manual
      expect(overridden_plan.conditions).to include(
        "provider_path" => "recipient.bank_code",
        "required_if" => { "internal_path" => "operation.payout_requisite.sbp", "present" => true }
      )
    end
  end

  describe "synthetic non-NovaPay provider" do
    it "maps renamed transfer, transaction, and notification endpoints generically" do
      result = mapper.call(synthetic_provider_spec)
      plan = result.value

      expect(result).to be_success
      expect(plan.provider_name).to eq("Orbit Transfer API")
      expect(plan.operation(:create_request).operation.path).to eq("/transfers")
      expect(plan.operation(:fetch_status).operation.path).to eq("/transactions/{transaction_id}")
      expect(plan.operation(:process_callback).operation.path).to eq("/notifications")
      expect(plan.field("operation.amount", direction: :request).provider_path).to eq("sum")
      expect(plan.field("operation.id", direction: :request).provider_path).to eq("reference_id")
      expect(plan.field("operation.payout_requisite.card_number", direction: :request).provider_path).to eq("beneficiary.card_number")
      expect(plan.statuses.mappings).to include(
        "queued" => "in_progress", "succeeded" => "approved", "declined" => "rejected"
      )
      expect(plan.security.name).to eq("X-Partner-Token")
      expect(plan.webhook.signature_header).to eq("Digest-Signature")
      expect(plan.webhook.signature_algorithm).to eq("HMAC-SHA512")
    end

    it "binds normalized idempotency headers to operation.id" do
      original = synthetic_provider_spec
      create = original.operations.first
      header = ProviderCompiler::Core::API::Parameter.new(
        name: "X-Idempotency-Key", location: "header", required: true, schema: api_schema(type: "string")
      )
      replacement = ProviderCompiler::Core::API::Operation.new(
        http_method: create.http_method, path: create.path, operation_id: create.operation_id,
        summary: create.summary, parameters: create.parameters + [header], request_body: create.request_body,
        responses: create.responses, security: create.security
      )
      provider = ProviderCompiler::Core::API::ProviderSpec.new(
        openapi_version: original.openapi_version, title: original.title,
        operations: [replacement, *original.operations.drop(1)], security_schemes: original.security_schemes,
        global_security: original.global_security
      )

      mapping = mapper.call(provider).value.metadata.fetch("request_headers").first
      expect(mapping).to include(
        "provider_name" => "X-Idempotency-Key", "source" => "operation.id", "required" => true
      )
    end

    it "maps single-enum required fetch parameters as safe constants" do
      original = synthetic_provider_spec
      fetch = original.operations[1]
      mode = ProviderCompiler::Core::API::Parameter.new(
        name: "mode", location: "query", required: true,
        schema: api_schema(type: "string", enum: ["current"])
      )
      replacement = api_operation(
        method: :get, path: fetch.path, operation_id: fetch.operation_id, summary: fetch.summary,
        parameters: fetch.parameters + [mode], responses: fetch.responses
      )
      provider = ProviderCompiler::Core::API::ProviderSpec.new(
        openapi_version: original.openapi_version, title: original.title,
        operations: [original.operations[0], replacement, original.operations[2]],
        security_schemes: original.security_schemes, global_security: original.global_security
      )

      result = mapper.call(provider)
      constants = result.value.metadata.fetch("request_parameter_constants")

      expect(result).to be_success
      expect(constants).to include(
        "operation_role" => "fetch_status", "provider_name" => "mode",
        "location" => "query", "value" => "current", "required" => true,
        "decision" => "auto",
        "evidence" => [{ "rule" => "single_enum_required_parameter_constant", "value" => "current" }]
      )
    end

    it "blocks unresolved required fetch parameters instead of omitting them" do
      original = synthetic_provider_spec
      fetch = original.operations[1]
      mode = ProviderCompiler::Core::API::Parameter.new(
        name: "mode", location: "query", required: true, schema: api_schema(type: "string")
      )
      replacement = api_operation(
        method: :get, path: fetch.path, operation_id: fetch.operation_id, summary: fetch.summary,
        parameters: fetch.parameters + [mode], responses: fetch.responses
      )
      provider = ProviderCompiler::Core::API::ProviderSpec.new(
        openapi_version: original.openapi_version, title: original.title,
        operations: [original.operations[0], replacement, original.operations[2]],
        security_schemes: original.security_schemes, global_security: original.global_security
      )

      result = mapper.call(provider)
      diagnostic = result.diagnostics.find { |item| item.code == "required_request_parameter_unresolved" }

      expect(result).to be_failure
      expect(diagnostic).not_to be_nil
      expect(diagnostic.metadata).to include(
        "operation_role" => "fetch_status", "provider_name" => "mode", "location" => "query"
      )
    end

    it "blocks ambiguous outbound security until the chosen scheme is persisted" do
      original = synthetic_provider_spec
      bearer = ProviderCompiler::Core::API::SecurityScheme.new(key: "Bearer", type: "http", scheme: "bearer")
      api_key = ProviderCompiler::Core::API::SecurityScheme.new(
        key: "Key", type: "apiKey", location: "header", name: "X-Key"
      )
      provider = ProviderCompiler::Core::API::ProviderSpec.new(
        openapi_version: original.openapi_version, title: original.title, operations: original.operations,
        security_schemes: { "Bearer" => bearer, "Key" => api_key },
        global_security: [{ "Bearer" => [] }, { "Key" => [] }]
      )

      unresolved = mapper.call(provider)
      resolved = mapper.call(provider, overrides: { security: { scheme_key: "Key" } })
      expect(unresolved).to be_failure
      expect(unresolved.diagnostics.map(&:code)).to include("security_mapping_needs_review")
      expect(resolved).to be_success
      expect(resolved.value.security).to be_manual
      expect(resolved.value.security).to be_api_key
      expect(resolved.value.security.name).to eq("X-Key")
      expect(resolved.diagnostics.map(&:code)).not_to include("security_mapping_needs_review")
    end

    it "blocks unsupported constructs only when they affect selected operations" do
      original = synthetic_provider_spec
      create = original.operations.first
      schema = create.request_body.schema
      composed = ProviderCompiler::Core::API::Schema.new(
        type: schema.type, properties: schema.properties, required: schema.required,
        unsupported_features: ["oneOf"]
      )
      critical_create = ProviderCompiler::Core::API::Operation.new(
        http_method: create.http_method, path: create.path, operation_id: create.operation_id,
        summary: create.summary,
        request_body: ProviderCompiler::Core::API::RequestBody.new(
          required: true, content_type: "application/json", schema: composed
        ),
        responses: create.responses
      )
      critical = ProviderCompiler::Core::API::ProviderSpec.new(
        openapi_version: original.openapi_version, title: original.title,
        operations: [critical_create, *original.operations.drop(1)],
        security_schemes: original.security_schemes, global_security: original.global_security
      )
      irrelevant = api_operation(
        method: :get, path: "/balance", operation_id: "getBalance",
        responses: { "200" => api_response(200, schema: ProviderCompiler::Core::API::Schema.new(
          type: "object", unsupported_features: ["oneOf"]
        )) }
      )
      safe = ProviderCompiler::Core::API::ProviderSpec.new(
        openapi_version: original.openapi_version, title: original.title,
        operations: original.operations + [irrelevant], security_schemes: original.security_schemes,
        global_security: original.global_security
      )

      expect(mapper.call(critical).diagnostics.map(&:code)).to include("critical_schema_composition_unsupported")
      expect(mapper.call(safe)).to be_success
    end

    it "blocks required non-JSON bodies and selected server overrides" do
      original = synthetic_provider_spec
      create = original.operations.first
      replacement = lambda do |body, source: nil|
        ProviderCompiler::Core::API::Operation.new(
          http_method: create.http_method, path: create.path, operation_id: create.operation_id,
          summary: create.summary, request_body: body, responses: create.responses,
          servers: source ? [ProviderCompiler::Core::API::Server.new(url: "https://special.example")] : [],
          server_source: source
        )
      end
      build_provider = lambda do |selected|
        ProviderCompiler::Core::API::ProviderSpec.new(
          openapi_version: original.openapi_version, title: original.title,
          operations: [selected, *original.operations.drop(1)], security_schemes: original.security_schemes,
          global_security: original.global_security
        )
      end
      xml = ProviderCompiler::Core::API::RequestBody.new(
        required: true, content_type: "application/xml", schema: create.request_body.schema
      )

      expect(mapper.call(build_provider.call(replacement.call(xml))).diagnostics.map(&:code))
        .to include("critical_request_media_type_unsupported")
      expect(mapper.call(build_provider.call(replacement.call(create.request_body, source: "operation"))).diagnostics.map(&:code))
        .to include("critical_operation_servers_unsupported")
    end


    it "blocks required unknown Orbit requisites until an explicit field override" do
      provider_spec = input_provider_spec("02_orbit_cash_renamed_but_clear.yaml")
      unresolved = mapper.call(provider_spec)
      override = SpecPaths.fixture("overrides", "orbit_cash_overrides.yml")
      resolved = mapper.call(provider_spec, overrides: override)

      expect(unresolved).to be_failure
      expect(unresolved.diagnostics.map(&:code)).to include("payout_requisite_mapping_unresolved")
      expect(unresolved.value.fields.map(&:internal_path)).not_to include("operation.payout_requisite.card")
      expect(resolved).to be_success
      mapping = resolved.value.field("operation.payout_requisite.card_number", direction: :request)
      expect(mapping.provider_path).to eq("beneficiary.card")
      expect(mapping).to be_manual
      expect(resolved.value.metadata).not_to have_key("unknown_requisites")
    end

    it "blocks ambiguous critical Polaris operations until an operation override" do
      provider_spec = input_provider_spec("04_polaris_pay_ambiguous_operations.yaml")
      unresolved = mapper.call(provider_spec)
      override = SpecPaths.fixture("overrides", "polaris_operations_overrides.yml")
      resolved = mapper.call(provider_spec, overrides: override)

      expect(unresolved).to be_failure
      expect(unresolved.value.operation(:create_request)).to be_needs_review
      expect(unresolved.diagnostics.map(&:code)).to include("critical_operation_mapping_needs_review")
      expect(resolved).to be_success
      expect(resolved.value.operation(:create_request)).to be_manual
      expect(resolved.value.operation(:create_request).operation.path).to eq("/payments")
    end

    it "recognizes Sable merchant and provider order identifiers despite the missing callback" do
      result = mapper.call(input_provider_spec("05_sable_money_missing_callback.yaml"))
      plan = result.value

      expect(result).to be_failure
      expect(plan.field("operation.id", direction: :request).provider_path).to eq("merchant_reference")
      expect(plan.field("operation.provider_operation_key", direction: :response).provider_path).to eq("order_id")
      expect(plan.field("operation.provider_operation_key", direction: :request).provider_path).to eq("order_id")
      id_failures = result.diagnostics.select do |item|
        item.code == "field_mapping_unresolved" &&
          %w[operation.id operation.provider_operation_key].include?(item.location)
      end
      expect(id_failures).to be_empty
      expect(result.diagnostics.map(&:code)).to include("operation_mapping_unresolved", "webhook_mapping_unresolved")
    end

    it "recognizes Vector disbursement ids and reports every unknown requisite by requiredness" do
      result = mapper.call(input_provider_spec("06_vector_bank_unknown_requisites.yaml"))
      plan = result.value

      expect(result).to be_failure
      expect(plan.field("operation.provider_operation_key", direction: :response).provider_path).to eq("disbursement_id")
      expect(plan.field("operation.provider_operation_key", direction: :request).provider_path).to eq("disbursement_id")
      expect(plan.webhook.provider_operation_id_path).to eq("disbursement_id")
      expect(result.diagnostics.map(&:code)).not_to include("field_mapping_unresolved", "webhook_mapping_needs_review")
      required = result.diagnostics.find { |item| item.code == "payout_requisite_mapping_unresolved" }
      optional = result.diagnostics.find { |item| item.code == "payout_requisite_mapping_needs_review" }
      expect(required.metadata).to include(
        "fields" => %w[beneficiary.iban beneficiary.tax_id], "required" => true
      )
      expect(optional.metadata).to include(
        "fields" => ["beneficiary.account_name"], "required" => false
      )
    end
  end
end
