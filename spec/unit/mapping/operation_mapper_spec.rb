# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::OperationMapper do
  subject(:mapper) { described_class.new }

  it "selects all three roles for a provider with generic endpoint names" do
    matches = mapper.call(synthetic_provider_spec)

    expect(matches.keys).to contain_exactly("create_request", "fetch_status", "process_callback")
    expect(matches["create_request"].candidate.path).to eq("/transfers")
    expect(matches["fetch_status"].candidate.path).to eq("/transactions/{transaction_id}")
    expect(matches["process_callback"].candidate.path).to eq("/notifications")
    expect(matches.values).to all(be_auto)
  end

  it "marks close candidates as needs_review and exposes alternatives" do
    first = api_operation(method: :post, path: "/transfers", operation_id: "createTransfer", responses: {})
    second = api_operation(method: :post, path: "/payments", operation_id: "createPayment", responses: {})
    spec = ProviderCompiler::Core::API::ProviderSpec.new(openapi_version: "3.0.3", operations: [first, second])

    match = mapper.call(spec)["create_request"]
    expect(match).to be_needs_review
    expect(match.alternatives.first["candidate"]).to eq(second).or eq(first)
    expect(match.metadata["margin"]).to eq(0)
  end

  it "returns unresolved matches when no candidate clears the review threshold" do
    operation = api_operation(method: :get, path: "/health", operation_id: "health", responses: {})
    spec = ProviderCompiler::Core::API::ProviderSpec.new(openapi_version: "3.0.3", operations: [operation])

    expect(mapper.call(spec).values).to all(be_unresolved)
  end
end
