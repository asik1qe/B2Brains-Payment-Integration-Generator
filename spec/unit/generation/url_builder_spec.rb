# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Generation::UrlBuilder do
  subject(:builder) { described_class.new }

  def operation_mapping(path, role: "fetch_status")
    operation = api_operation(method: :get, path: path)
    ProviderCompiler::Core::Mapping::OperationMapping.new(role: role, operation: operation)
  end

  def path_field(provider_path, internal_path)
    ProviderCompiler::Core::Mapping::FieldMapping.new(
      internal_path: internal_path,
      provider_path: provider_path,
      direction: :request,
      metadata: { "operation_role" => "fetch_status", "source" => "parameter", "location" => "path" }
    )
  end

  it "renders static paths as safe Ruby literals" do
    result = builder.build(operation_mapping: operation_mapping("/transfers"), field_mappings: [])

    expect(result).to be_success
    expect(result.value).to eq('"/transfers"')
  end

  it "interpolates one or several exactly mapped path parameters" do
    one = builder.build(
      operation_mapping: operation_mapping("/transactions/{transaction_id}"),
      field_mappings: [path_field("transaction_id", "operation.provider_operation_key")]
    )
    several = builder.build(
      operation_mapping: operation_mapping("/accounts/{account_id}/transfers/{transfer_id}"),
      field_mappings: [
        path_field("account_id", "operation.payout_requisite"),
        path_field("transfer_id", "operation.provider_operation_key")
      ]
    )

    expect(one.value).to eq('"/transactions/#{operation.provider_operation_key}"')
    expect(several.value).to eq(
      '"/accounts/#{operation.payout_requisite}/transfers/#{operation.provider_operation_key}"'
    )
  end

  it "does not replace similar static substrings or query parameters" do
    mapping = operation_mapping("/transaction_id/{transaction_id}")
    field = path_field("transaction_id", "operation.provider_operation_key")

    expect(builder.build(operation_mapping: mapping, field_mappings: [field]).value).to eq(
      '"/transaction_id/#{operation.provider_operation_key}"'
    )
  end

  it "returns a blocking diagnostic for missing or unsafe mappings" do
    missing = builder.build(operation_mapping: operation_mapping("/things/{id}"), field_mappings: [])
    unsafe = builder.build(
      operation_mapping: operation_mapping("/things/{id}"),
      field_mappings: [path_field("id", "operation.id; system('bad')")]
    )

    expect(missing).to be_failure
    expect(missing.diagnostics.first.code).to eq("path_parameter_mapping_missing")
    expect(unsafe).to be_failure
    expect(unsafe.diagnostics.first.code).to eq("unsafe_field_expression")
  end
end
