# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::Overrides do
  let(:provider_spec) { synthetic_provider_spec }
  let(:original_plan) { ProviderCompiler::Mapping::Mapper.new.call(provider_spec).value }

  it "loads YAML safely and rejects malformed or unsafe YAML" do
    valid = Tempfile.new(["overrides", ".yml"])
    invalid = Tempfile.new(["overrides", ".yml"])
    valid.write("statuses:\n  settled: approved\n")
    invalid.write("--- !ruby/object:Object {}\n")
    valid.close
    invalid.close

    expect(described_class.load(valid.path)).to be_success
    failed = described_class.load(invalid.path)
    expect(failed).to be_failure
    expect(failed.diagnostics.first.code).to eq("override_parse_error")
  ensure
    valid&.unlink
    invalid&.unlink
  end

  it "overrides operations by operationId and method/path with manual decisions" do
    overrides = described_class.new(
      operations: {
        create_request: { operation_id: "retrieveTransaction" },
        fetch_status: { method: "POST", path: "/transfers" }
      }
    )
    result = overrides.apply(original_plan, provider_spec: provider_spec)

    expect(result.value.operation(:create_request).operation.operation_id).to eq("retrieveTransaction")
    expect(result.value.operation(:fetch_status).operation.path).to eq("/transfers")
    expect(result.value.operation(:create_request)).to be_manual
    expect(original_plan.operation(:create_request).operation.path).to eq("/transfers")
  end

  it "reports an unresolved operation override" do
    result = described_class.new(
      operations: { create_request: { operation_id: "missing" } }
    ).apply(original_plan, provider_spec: provider_spec)

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("override_operation_not_found")
  end

  it "patches and creates fields without mutating the original plan" do
    result = described_class.new(
      fields: {
        "operation.amount" => {
          direction: "request",
          provider_path: "total_minor",
          transformation: { type: "money", unit: "minor_units", factor: 1000 }
        },
        "operation.provider_operation_key" => {
          direction: "webhook",
          provider_path: "transaction_id"
        }
      }
    ).apply(original_plan, provider_spec: provider_spec)

    amount = result.value.field("operation.amount", direction: :request)
    created = result.value.field("operation.provider_operation_key", direction: :webhook)
    expect(amount.provider_path).to eq("total_minor")
    expect(amount.transformation["factor"]).to eq(1000)
    expect(amount).to be_manual
    expect(created).to be_manual
    expect(original_plan.field("operation.amount", direction: :request).provider_path).to eq("sum")
  end

  it "gives a confirmed logical field precedence across matching response and path mappings" do
    logical_fields = original_plan.fields.select do |field|
      field.internal_path == "operation.provider_operation_key" && field.provider_path == "transaction_id"
    end
    response_field = logical_fields.find(&:response?)
    diagnostic = ProviderCompiler::Core::Diagnostic.new(
      severity: :warning,
      code: :field_mapping_needs_review,
      message: "Field mapping requires review",
      stage: :mapping,
      state: :needs_review,
      location: "operation.provider_operation_key"
    )
    plan = ProviderCompiler::Core::Mapping::MappingPlan.new(
      provider_name: original_plan.provider_name,
      operations: original_plan.operations,
      fields: original_plan.fields.reject do |field|
        field.internal_path == "operation.provider_operation_key" && field.provider_path == "transaction_id"
      end + [response_field],
      statuses: original_plan.statuses,
      errors: original_plan.errors,
      security: original_plan.security,
      webhook: original_plan.webhook,
      conditions: original_plan.conditions,
      diagnostics: original_plan.diagnostics + [diagnostic],
      metadata: original_plan.metadata
    )
    result = described_class.new(
      fields: {
        "operation.provider_operation_key" => {
          direction: logical_fields.first.direction,
          provider_path: "transaction_id"
        }
      }
    ).apply(plan, provider_spec: provider_spec)

    confirmed = result.value.fields.select do |field|
      field.internal_path == "operation.provider_operation_key" && field.provider_path == "transaction_id"
    end
    expect(confirmed.length).to be >= 2
    expect(confirmed).to all(be_manual)
    expect(result.diagnostics.map(&:code)).not_to include("field_mapping_needs_review")
  end

  it "merges statuses and patches security, webhook, and conditions" do
    overrides = described_class.new(
      statuses: { settled: "approved" },
      security: { credential_path: "partner_api_key" },
      webhook: {
        signature_encoding: "hex",
        signed_payload: "raw_body",
        secret_credential_path: "webhook_secret"
      },
      conditions: [
        { provider_path: "beneficiary.account", required_if: { path: "beneficiary.type", equals: "bank" } }
      ]
    )
    result = overrides.apply(original_plan, provider_spec: provider_spec)

    expect(result.value.statuses.map("settled")).to eq("approved")
    expect(result.value.statuses).to be_manual
    expect(result.value.security.credential_path).to eq("partner_api_key")
    expect(result.value.security).to be_manual
    expect(result.value.webhook.signature_encoding).to eq("hex")
    expect(result.value.webhook.signed_payload).to eq("raw_body")
    expect(result.value.webhook).to be_manual
    expect(result.value.conditions).to include(
      "provider_path" => "beneficiary.account",
      "required_if" => { "path" => "beneficiary.type", "equals" => "bank" }
    )
    expect(original_plan.webhook.signature_encoding).to be_nil
  end

  it "returns override_invalid for invalid root and incomplete new fields" do
    invalid_root = described_class.new([]).apply(original_plan, provider_spec: provider_spec)
    invalid_field = described_class.new(
      fields: { "operation.id" => { direction: "webhook" } }
    ).apply(original_plan, provider_spec: provider_spec)

    expect(invalid_root).to be_failure
    expect(invalid_field).to be_failure
    expect(invalid_root.diagnostics.map(&:code)).to include("override_invalid")
    expect(invalid_field.diagnostics.map(&:code)).to include("override_invalid")
  end


  it "resolves required unknown requisites through a confirmed manual field mapping" do
    provider = input_provider_spec("02_orbit_cash_renamed_but_clear.yaml")
    plan = ProviderCompiler::Mapping::Mapper.new.call(provider).value
    result = described_class.new(
      fields: {
        "operation.payout_requisite.card_number" => {
          direction: "request", provider_path: "beneficiary.card", required: true
        }
      }
    ).apply(plan, provider_spec: provider)

    expect(result).to be_success
    expect(result.diagnostics.map(&:code)).not_to include("payout_requisite_mapping_unresolved")
    mapping = result.value.field("operation.payout_requisite.card_number", direction: :request)
    expect(mapping).to be_manual
    expect(mapping.metadata).to include("operation_role" => "create_request", "source" => "request_body")
  end

  it "resolves multiple required provider fields bound to one explicit internal source" do
    provider = input_provider_spec("02_atlasbank_basic_iban_review.yaml")
    plan = ProviderCompiler::Mapping::Mapper.new.call(provider).value
    result = described_class.new(
      fields: {
        "operation.payout_requisite.card_number" => [
          { direction: "request", provider_path: "beneficiary.iban", required: true },
          { direction: "request", provider_path: "beneficiary.tax_id", required: true }
        ]
      }
    ).apply(plan, provider_spec: provider)

    mappings = result.value.fields.select do |field|
      field.internal_path == "operation.payout_requisite.card_number" && field.direction == "request"
    end
    expect(mappings.map(&:provider_path)).to contain_exactly("beneficiary.iban", "beneficiary.tax_id")
    expect(mappings).to all(be_manual)
    expect(result.diagnostics.map(&:code)).not_to include("payout_requisite_mapping_unresolved")
  end

  it "clears critical review diagnostics only for an explicitly selected operation" do
    provider = input_provider_spec("04_polaris_pay_ambiguous_operations.yaml")
    plan = ProviderCompiler::Mapping::Mapper.new.call(provider).value
    result = described_class.new(
      operations: { create_request: { method: "POST", path: "/payments" } }
    ).apply(plan, provider_spec: provider)

    expect(result).to be_success
    expect(result.value.operation(:create_request)).to be_manual
    expect(result.diagnostics.map(&:code)).not_to include(
      "critical_operation_mapping_needs_review", "operation_mapping_needs_review"
    )
  end
end
