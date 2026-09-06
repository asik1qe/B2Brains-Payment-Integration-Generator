# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Generation::ServiceRenderer do
  subject(:renderer) { described_class.new }

  let(:plan) { orbit_mapping_plan }
  let(:source) { renderer.render(mapping_plan: plan, class_name: "OrbitTransferService") }

  def copy_plan(source_plan, fields: source_plan.fields, security: source_plan.security, metadata: source_plan.metadata)
    ProviderCompiler::Core::Mapping::MappingPlan.new(
      provider_name: source_plan.provider_name,
      operations: source_plan.operations,
      fields: fields,
      statuses: source_plan.statuses,
      errors: source_plan.errors,
      security: security,
      webhook: source_plan.webhook,
      conditions: source_plan.conditions,
      diagnostics: source_plan.diagnostics,
      metadata: metadata
    )
  end

  it "renders a syntactically valid service with all contract methods" do
    expect { RubyVM::InstructionSequence.compile(source) }.not_to raise_error
    expect(source).to include("class Provider::OrbitTransferService < Provider::BaseService")
    ProviderCompiler::Core::SpacePaymentsContract::REQUIRED_SERVICE_METHODS.each do |method|
      expect(source).to include("def #{method}")
    end
  end

  it "renders mapped methods, paths, request fields, and transformations" do
    expect(source).to include('response = client.post(url, headers: headers, body: body)')
    expect(source).to include('url = "/transfers"')
    expect(source).to include('url = "/transactions/#{operation.provider_operation_key}"')
    expect(source).to include('"sum" => (operation.amount.nil? ? nil : operation.amount * 100)')
    expect(source).to include('"reference_id" => (operation.id.nil? ? nil : operation.id.to_s)')
    expect(source).to include('put_value(body, "beneficiary.card_number", dig_value(operation.payout_requisite, "card_number"))')
    expect(source).to include('provider_id = dig_value(payload, "transaction_id")')
    expect(source).to include('success(result: { id: provider_id })')
    expect(source).not_to include("operation.provider_operation_key =")
  end

  it "renders only mapped security, statuses, and errors" do
    expect(source).to include('headers["X-Partner-Token"] = read_value(credentials, "api_key")')
    expect(source).to include('"queued" => "in_progress"')
    expect(source).to include('"succeeded" => "approved"')
    expect(source).to include('failure(:unauthorized, "provider_compiler.errors.unauthorized"')
    expect(source).to include('failure(:too_many_requests, "provider_compiler.errors.too_many_requests"')
    expect(source).to include('response_header(response, "Retry-After")')
  end

  it "renders mapped webhook paths and an explicit host-runtime TODO" do
    expect(source).to include('provider_status = dig_value(payload, "state")')
    expect(source).to include('provider_id = dig_value(payload, "transaction_id")')
    expect(source).to include('"header" => "Digest-Signature"')
    expect(source).to include('"algorithm" => "HMAC-SHA512"')
    expect(source).to include("Webhook signature verification requires host runtime access")
  end

  it "renders enum, date-time, and nested-object descriptors without semantic inference" do
    original_id = plan.field("operation.id", direction: :request)
    enum_field = ProviderCompiler::Core::Mapping::FieldMapping.new(
      internal_path: original_id.internal_path,
      provider_path: original_id.provider_path,
      direction: :request,
      transformation: { "type" => "enum", "mapping" => { "merchant" => "provider" } },
      metadata: original_id.metadata
    )
    date_field = ProviderCompiler::Core::Mapping::FieldMapping.new(
      internal_path: "operation.id",
      provider_path: "scheduled_at",
      direction: :request,
      transformation: { "type" => "date_time", "format" => "date-time" },
      metadata: original_id.metadata
    )
    existing_requisite = plan.fields.find { |field| field.internal_path.start_with?("operation.payout_requisite") }
    requisite = ProviderCompiler::Core::Mapping::FieldMapping.new(
      internal_path: "operation.payout_requisite",
      provider_path: "beneficiary",
      direction: :request,
      decision: :manual,
      metadata: { "operation_role" => "create_request", "source" => "request_body" }
    )
    nested_field = ProviderCompiler::Core::Mapping::FieldMapping.new(
      internal_path: requisite.internal_path,
      provider_path: requisite.provider_path,
      direction: :request,
      transformation: { "type" => "nested_object", "provider_path" => "beneficiary" },
      metadata: requisite.metadata
    )
    fields = plan.fields.reject { |field| [original_id, existing_requisite].include?(field) } + [enum_field, date_field, nested_field]
    rendered = renderer.render(mapping_plan: copy_plan(plan, fields: fields), class_name: "TransformsService")

    expect(rendered).to include("map_enum(", ".iso8601", '"beneficiary" => operation.payout_requisite')
    expect { RubyVM::InstructionSequence.compile(rendered) }.not_to raise_error
  end

  it "renders query API keys, bearer tokens, and basic credentials according to SecurityMapping" do
    query = ProviderCompiler::Core::Mapping::SecurityMapping.new(
      type: "apiKey", location: "query", name: "access_key", credential_path: "api_key"
    )
    bearer = ProviderCompiler::Core::Mapping::SecurityMapping.new(
      type: "bearer", location: "header", name: "Authorization", credential_path: "token", prefix: "Bearer"
    )
    basic = ProviderCompiler::Core::Mapping::SecurityMapping.new(
      type: "basic",
      location: "header",
      name: "Authorization",
      parameters: { "username_path" => "username", "password_path" => "password" }
    )

    query_source = renderer.render(mapping_plan: copy_plan(plan, security: query), class_name: "QueryService")
    bearer_source = renderer.render(mapping_plan: copy_plan(plan, security: bearer), class_name: "BearerService")
    basic_source = renderer.render(mapping_plan: copy_plan(plan, security: basic), class_name: "BasicService")

    expect(query_source).to include('query["access_key"]', 'query: query')
    expect(query_source).not_to include('headers["access_key"]')
    expect(bearer_source).to include('headers["Authorization"] = ["Bearer", read_value(credentials, "token")].join(" ")')
    expect(basic_source).to include('require "base64"', "basic_auth_value")
    expect { RubyVM::InstructionSequence.compile(basic_source) }.not_to raise_error
  end

  it "does not contain provider-specific fallback logic" do
    expect(source).not_to include("NovaPay", "/payouts", "createPayout")
  end

  it "renders confirmed SBP/card variants and the official create result for NovaPay" do
    nova = renderer.render(mapping_plan: novapay_mapping_plan, class_name: "NovaPayService")

    expect(nova).to include(
      'class Provider::NovaPayService < Provider::BaseService',
      'BASE_URL = ENV.fetch("NOVA_PAY_BASE_URL", "https://api.sandbox.novapay.example/v1")',
      'def check_conditions(operation, request_method = nil)',
      'def create_request(operation, request_method = nil, *args, **kwargs)',
      'dig_value(operation.payout_requisite, "sbp.phone")',
      'dig_value(operation.payout_requisite, "sbp.bank_code")',
      'dig_value(operation.payout_requisite, "card_number")',
      'put_value(body, "recipient.type", "sbp")',
      'put_value(body, "recipient.type", "card")',
      'headers["Idempotency-Key"] = operation.id.to_s',
      '"currency" => "RUB"',
      '"external_id" => (operation.id.nil? ? nil : operation.id.to_s)',
      'selected_variant = request_variant(operation)',
      'case request_variant(operation)',
      'return failure(:internal_server_error, "provider_compiler.errors.provider_operation_key_missing") if provider_id.nil? || provider_id.to_s.empty?',
      'success(result: { id: provider_id })',
      'return failure(:bad_request, "provider_compiler.errors.provider_operation_key_missing") if operation.provider_operation_key.nil? || operation.provider_operation_key.to_s.empty?',
      'url = build_url("/payouts/#{operation.provider_operation_key}")',
      'return failure(:unprocessable_entity, "provider_compiler.errors.provider_operation_key_missing") if provider_id.nil? || provider_id.to_s.empty?',
      "approve_operation(",
      "reject_operation("
    )
    expect(nova).not_to include(
      '"recipient" => operation.payout_requisite',
      "operation.provider_operation_key =",
      "operation.provider_operation_id",
      "request.raw_body",
      "request.headers"
    )
  end

  it "renders required constant parameters for fetch_status" do
    metadata = plan.metadata.merge(
      "request_parameter_constants" => [
        {
          "operation_role" => "fetch_status", "provider_name" => "mode",
          "location" => "query", "value" => "current", "required" => true,
          "decision" => "auto"
        }
      ]
    )
    rendered = renderer.render(
      mapping_plan: copy_plan(plan, metadata: metadata), class_name: "FetchConstantService"
    )

    expect(rendered).to include('query["mode"] = "current"')
    expect(rendered).to include('response = client.get(url, headers: headers, query: query)')
    expect { RubyVM::InstructionSequence.compile(rendered) }.not_to raise_error
  end

  it "does not invent an idempotency header when MappingPlan has no binding" do
    expect(source).not_to match(/headers\[[^\]]*Idempotency/i)
  end

  it "blocks unresolved or unsupported outbound security" do
    ambiguous = ProviderCompiler::Core::Mapping::SecurityMapping.new(
      type: "apiKey", location: "header", name: "X-Key", decision: :needs_review
    )
    renderer.render(mapping_plan: copy_plan(plan, security: ambiguous), class_name: "AmbiguousSecurityService")

    expect(renderer.diagnostics.map(&:code)).to include("security_mapping_unresolved")
    expect(renderer.diagnostics).to all(be_blocking)
  end

  it "deeply inserts variant fields without replacing sibling request fields" do
    amount = plan.field("operation.amount", direction: :request)
    reference = plan.field("operation.id", direction: :request)
    card = plan.fields.find { |field| field.internal_path.end_with?("card_number") }
    nested_fields = [
      ProviderCompiler::Core::Mapping::FieldMapping.new(
        internal_path: amount.internal_path,
        provider_path: "payment.amount",
        direction: :request,
        transformation: amount.transformation,
        metadata: amount.metadata
      ),
      ProviderCompiler::Core::Mapping::FieldMapping.new(
        internal_path: reference.internal_path,
        provider_path: "payment.reference",
        direction: :request,
        metadata: reference.metadata
      ),
      ProviderCompiler::Core::Mapping::FieldMapping.new(
        internal_path: card.internal_path,
        provider_path: "payment.recipient.card_number",
        direction: :request,
        decision: :manual,
        metadata: card.metadata.merge("request_variant" => "card")
      )
    ]
    fields = plan.fields.reject { |field| [amount.internal_path, reference.internal_path, card.internal_path].include?(field.internal_path) }
    nested_plan = copy_plan(
      plan,
      fields: fields + nested_fields,
      metadata: plan.metadata.merge(
        "request_variants" => [{
          "name" => "card",
          "when" => { "path" => "operation.payout_requisite.card_number", "present" => true },
          "constants" => {}
        }]
      )
    )

    rendered = renderer.render(mapping_plan: nested_plan, class_name: "NestedService")

    expect(rendered).to include(
      '"payment" => {',
      '"amount" =>',
      '"reference" =>',
      'put_value(body, "payment.recipient.card_number"'
    )
    expect(rendered).not_to include("body.merge!")
    expect { RubyVM::InstructionSequence.compile(rendered) }.not_to raise_error
  end

  it "renders platform failure codes and amount-limit validation policy" do
    nova = renderer.render(mapping_plan: novapay_mapping_plan, class_name: "NovaPayService")

    expect(nova).to include(
      "when 400", ":bad_request",
      "when 401", ":unauthorized",
      "when 402", ":unprocessable_entity",
      "when 422", ":unprocessable_entity",
      "when 429", ":too_many_requests",
      "when 500", ":internal_server_error",
      'provider_code: dig_value(response_body(response), "error.code")'
    )
    expect(nova).not_to include('when "amount_limit_exceeded"')
  end

  it "reports incomplete mapping data instead of guessing" do
    incomplete = ProviderCompiler::Core::Mapping::MappingPlan.new(provider_name: "Incomplete")
    generated = renderer.render(mapping_plan: incomplete, class_name: "IncompleteService")

    expect(generated).to include(
      'failure(:internal_server_error, "provider_compiler.errors.generation_mapping_missing"'
    )
    expect(renderer.diagnostics).to all(be_blocking)
    expect(renderer.diagnostics.map(&:code)).to include("generation_mapping_missing")
  end
end
