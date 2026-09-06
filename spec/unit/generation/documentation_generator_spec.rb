# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Generation::DocumentationGenerator do
  subject(:generator) { described_class.new }

  let(:plan) { novapay_mapping_plan }
  let(:markdown) do
    generator.generate(
      mapping_plan: plan,
      provider_spec: novapay_provider_spec,
      service_filename: "nova_pay_payout_api_service.rb"
    )
  end

  it "documents provider, generated files, servers, authentication, and operations" do
    expect(markdown).to include("# NovaPay Payout API Integration")
    expect(markdown).to include("## Generated files / Service", "`nova_pay_payout_api_service.rb`")
    expect(markdown).to include("https://api.sandbox.novapay.example/v1")
    expect(markdown).to include("## Authentication", "`apiKey`", "`X-API-Key`")
    expect(markdown).to include("### create_request", "`POST /payouts`")
    expect(markdown).to include("### fetch_status", "`GET /payouts/{payout_id}`")
    expect(markdown).to include("### process_callback", "`POST /webhooks/payout`")
  end

  it "documents fields, transformations, conditions, statuses, errors, and webhook" do
    expect(markdown).to include("## Field mapping", "`operation.amount`", "`external_id`")
    expect(markdown).to include("## Transformations", 'factor=100', 'unit="kopecks"')
    expect(markdown).to include("## Conditions", "minimum", "recipient.phone")
    expect(markdown).to include("## Status mapping", "`completed` → `approved`")
    expect(markdown).to include("## Error mapping", "`too_many_requests`", "Retry-After")
    expect(markdown).to include("## Webhook", "`X-NovaPay-Signature`", "`HMAC-SHA256`")
  end

  it "marks manual decisions and external runtime limitations" do
    expect(markdown).to include("## Assumptions / Manual decisions / Review notes")
    expect(markdown).to include("mapping decision(s) were confirmed manually")
    expect(markdown).to include("process_callback(payload)", "parsed JSON", "raw body and signature header")
    expect(markdown).not_to include("Unbound request headers require manual policy: `Idempotency-Key`")
  end

  it "documents the official create, provider key, requisite, and lifecycle contracts" do
    expect(markdown).to include(
      "success(result: { id: provider_id })",
      "operation.provider_operation_key",
      "operation.payout_requisite.sbp.*",
      "operation.payout_requisite.card_number",
      "approve_operation",
      "reject_operation"
    )
  end

  it "leaves unconfirmed ProviderGateway settings as TODOs and contains no secrets" do
    expect(markdown).to include("## ProviderGateway config", "external_method: TODO", "gateway: TODO")
    expect(markdown).not_to include("sbp_payout", "RUB_SBP_WITHDRAW")
    expect(markdown).not_to include("integration@novapay.example")
  end

  it "uses ProviderGateway values only when they are explicit MappingPlan metadata" do
    explicit = ProviderCompiler::Core::Mapping::MappingPlan.new(
      provider_name: plan.provider_name,
      operations: plan.operations,
      fields: plan.fields,
      statuses: plan.statuses,
      errors: plan.errors,
      security: plan.security,
      webhook: plan.webhook,
      conditions: plan.conditions,
      diagnostics: plan.diagnostics,
      metadata: plan.metadata.merge("external_method" => "configured_method", "gateway" => "CONFIGURED_GATEWAY")
    )
    rendered = generator.generate(
      mapping_plan: explicit,
      provider_spec: novapay_provider_spec,
      service_filename: "service.rb"
    )

    expect(rendered).to include("external_method: configured_method", "gateway: CONFIGURED_GATEWAY")
  end


  it "documents unknown provider requisites as manual TODOs without inventing accessors" do
    unknown_plan = ProviderCompiler::Mapping::Mapper.new.call(unknown_requisite_provider_spec).value
    unknown_markdown = generator.generate(
      mapping_plan: unknown_plan,
      provider_spec: unknown_requisite_provider_spec,
      service_filename: "unknown_service.rb"
    )
    unknown_source = ProviderCompiler::Generation::ServiceRenderer.new.render(
      mapping_plan: unknown_plan,
      class_name: "UnknownService"
    )

    expect(unknown_markdown).to include(
      "TODO/manual mapping required",
      "recipient.iban (required=true)",
      "recipient.tax_id (required=true)",
      "recipient.account_name (required=false)"
    )
    expect(unknown_source).not_to include(
      'payout_requisite["iban"]', 'payout_requisite["tax_id"]', 'payout_requisite["account_name"]'
    )
  end
end
