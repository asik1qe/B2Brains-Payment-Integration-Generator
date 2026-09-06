# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::FieldMapper do
  subject(:mapper) { described_class.new }

  let(:provider_spec) { synthetic_provider_spec }
  let(:matches) { ProviderCompiler::Mapping::OperationMapper.new.call(provider_spec) }

  it "maps create request, create response, and fetch path fields by structure" do
    fields = mapper.call(provider_spec: provider_spec, operation_matches: matches)

    expect(fields.map { |field| [field.internal_path, field.provider_path, field.direction] }).to include(
      ["operation.amount", "sum", "request"],
      ["operation.id", "reference_id", "request"],
      ["operation.payout_requisite.card_number", "beneficiary.card_number", "request"],
      ["operation.provider_operation_key", "transaction_id", "response"],
      ["operation.provider_operation_key", "transaction_id", "request"]
    )
    expect(fields.map(&:internal_path).uniq).to contain_exactly(
      "operation.amount", "operation.id", "operation.payout_requisite.card_number", "operation.provider_operation_key"
    )
    expect(fields).to all(satisfy { |field| field.evidence.any? })
  end

  it "maps confirmed nested requisites without inventing provider-shaped internal paths" do
    fields = mapper.call(provider_spec: provider_spec, operation_matches: matches)
    requisite = fields.find { |field| field.internal_path == "operation.payout_requisite.card_number" }

    expect(requisite.provider_path).to eq("beneficiary.card_number")
    expect(fields.map(&:internal_path)).not_to include("operation.payout_requisite.account")
  end

  it "adds a review diagnostic when a money unit comes only from schema text" do
    amount = mapper.call(provider_spec: provider_spec, operation_matches: matches).find do |field|
      field.internal_path == "operation.amount"
    end

    expect(amount.transformation).to eq("type" => "money", "unit" => "cents", "factor" => 100)
    expect(mapper.diagnostics.map(&:code)).to include("money_unit_needs_review")
  end

  it "marks tied field candidates for review" do
    create = provider_spec.operations.first
    schema = api_schema(
      type: "object",
      properties: {
        "amount" => api_schema(type: "integer"),
        "sum" => api_schema(type: "integer"),
        "reference_id" => api_schema(type: "string"),
        "beneficiary" => api_schema(type: "object")
      }
    )
    tied = api_operation(
      method: :post,
      path: create.path,
      operation_id: create.operation_id,
      request_schema: schema,
      responses: create.responses
    )
    spec = ProviderCompiler::Core::API::ProviderSpec.new(
      openapi_version: "3.0.3",
      operations: [tied, provider_spec.operations[1], provider_spec.operations[2]]
    )
    operation_matches = ProviderCompiler::Mapping::OperationMapper.new.call(spec)

    fields = mapper.call(provider_spec: spec, operation_matches: operation_matches)
    expect(fields.find { |field| field.internal_path == "operation.amount" }).to be_needs_review
    expect(mapper.diagnostics.map(&:code)).to include("field_mapping_needs_review")
  end

  it "emits blocking diagnostics when critical fields are absent" do
    empty = api_operation(method: :post, path: "/transfers", operation_id: "createTransfer", request_schema: api_schema(type: "object"), responses: {})
    spec = ProviderCompiler::Core::API::ProviderSpec.new(openapi_version: "3.0.3", operations: [empty])
    operation_matches = { "create_request" => empty }

    expect(mapper.call(provider_spec: spec, operation_matches: operation_matches)).to be_empty
    expect(mapper.diagnostics.map(&:code)).to include("field_mapping_unresolved")
    expect(mapper.diagnostics).to all(be_blocking)
  end

  it "maps confirmed NovaPay SBP and card fields without flattening operation attributes" do
    fields = mapper.call(
      provider_spec: novapay_provider_spec,
      operation_matches: ProviderCompiler::Mapping::OperationMapper.new.call(novapay_provider_spec)
    )

    expect(fields.map { |field| [field.internal_path, field.provider_path] }).to include(
      ["operation.payout_requisite.sbp.phone", "recipient.phone"],
      ["operation.payout_requisite.sbp.bank_code", "recipient.bank_code"],
      ["operation.payout_requisite.sbp.bank_name", "recipient.bank_name"],
      ["operation.payout_requisite.card_number", "recipient.card_number"]
    )
    expect(mapper.request_variants.map { |variant| variant["name"] }).to eq(%w[sbp card])
  end

  it "blocks required unknown provider requisites without inventing internal paths" do
    unknown_spec = unknown_requisite_provider_spec
    fields = mapper.call(
      provider_spec: unknown_spec,
      operation_matches: ProviderCompiler::Mapping::OperationMapper.new.call(unknown_spec)
    )

    expect(fields.map(&:internal_path)).not_to include(
      "operation.payout_requisite.iban", "operation.payout_requisite.tax_id"
    )
    expect(fields.map(&:internal_path)).not_to include("operation.payout_requisite")
    diagnostic = mapper.diagnostics.find { |item| item.code == "payout_requisite_mapping_unresolved" }
    expect(diagnostic).to be_blocking
    expect(diagnostic.metadata).to include(
      "fields" => %w[recipient.iban recipient.tax_id],
      "required" => true
    )
    optional = mapper.diagnostics.find { |item| item.code == "payout_requisite_mapping_needs_review" }
    expect(optional).to be_needs_review
    expect(optional.metadata).to include("fields" => ["recipient.account_name"], "required" => false)
  end
end
