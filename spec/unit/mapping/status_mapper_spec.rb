# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::StatusMapper do
  subject(:mapper) { described_class.new }

  it "maps common provider statuses to the three contract statuses" do
    provider_spec = synthetic_provider_spec
    status = mapper.call(
      provider_spec: provider_spec,
      operation_matches: ProviderCompiler::Mapping::OperationMapper.new.call(provider_spec)
    )

    expect(status.mappings).to include(
      "queued" => "in_progress", "succeeded" => "approved", "declined" => "rejected"
    )
    expect(status).to be_auto
    expect(mapper.diagnostics).to be_empty
  end

  it "covers canonical pending/completed/failed variants" do
    response_schema = api_schema(
      type: "object",
      properties: {
        "status" => api_schema(
          type: "string",
          enum: %w[pending processing completed failed cancelled successful rejected awaiting]
        )
      }
    )
    operation = api_operation(method: :get, path: "/status", responses: { "200" => api_response(200, schema: response_schema) })
    status = mapper.call(provider_spec: synthetic_provider_spec, operation_matches: { "fetch_status" => operation })

    expect(status.map("pending")).to eq("in_progress")
    expect(status.map("completed")).to eq("approved")
    expect(status.map("cancelled")).to eq("rejected")
  end

  it "normalizes common payout aliases and semantic suffixes" do
    response_schema = api_schema(
      type: "object",
      properties: {
        "status" => api_schema(
          type: "string",
          enum: %w[new settled paid queued declined payment_settled PAYMENT-SETTLED transfer.new]
        )
      }
    )
    operation = api_operation(method: :get, path: "/status", responses: { "200" => api_response(200, schema: response_schema) })
    status = mapper.call(provider_spec: synthetic_provider_spec, operation_matches: { "fetch_status" => operation })

    expect(status.mappings).to include(
      "new" => "in_progress",
      "settled" => "approved",
      "paid" => "approved",
      "queued" => "in_progress",
      "declined" => "rejected",
      "payment_settled" => "approved",
      "PAYMENT-SETTLED" => "approved",
      "transfer.new" => "in_progress"
    )
  end

  it "does not guess an unknown provider status" do
    schema = api_schema(
      type: "object",
      properties: { "state" => api_schema(type: "string", enum: ["awaiting_bank_confirmation"]) }
    )
    operation = api_operation(method: :get, path: "/status", responses: { "200" => api_response(200, schema: schema) })
    status = mapper.call(provider_spec: synthetic_provider_spec, operation_matches: { "fetch_status" => operation })

    expect(status).to be_needs_review
    expect(status.mapped?("awaiting_bank_confirmation")).to be(false)
    expect(mapper.diagnostics.map(&:code)).to eq(["status_mapping_needs_review"])
  end

  it "is unresolved when no status enum exists" do
    operation = api_operation(method: :get, path: "/thing", responses: { "200" => api_response(200, schema: api_schema(type: "object")) })
    status = mapper.call(provider_spec: synthetic_provider_spec, operation_matches: { "fetch_status" => operation })

    expect(status).to be_unresolved
    expect(mapper.diagnostics.map(&:code)).to contain_exactly("status_path_unresolved", "status_mapping_unresolved")
  end
end
