# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::OperationRules do
  subject(:rules) { described_class.new }

  let(:operations) { synthetic_provider_spec.operations }

  it "strongly scores generic create, status, and callback shapes" do
    create, fetch, callback = operations

    expect(rules.score(create, :create_request)[:score]).to be >= 55
    expect(rules.score(fetch, :fetch_status)[:score]).to be >= 55
    expect(rules.score(callback, :process_callback)[:score]).to be >= 55
  end

  it "uses named weighted evidence and penalizes conflicting semantics" do
    create, _fetch, callback = operations
    assessment = rules.score(create, :create_request)

    expect(assessment[:evidence]).to all(include("rule", "weight", "reason"))
    expect(assessment[:evidence].map { |item| item["rule"] }).to include(
      "http_post", "create_action_keyword", "request_amount_shape", "request_recipient_shape"
    )
    expect(rules.score(callback, :create_request)[:score]).to be < assessment[:score]
  end

  it "tokenizes camelCase, paths, and Russian semantic words without changing operations" do
    operation = api_operation(
      method: :post,
      path: "/money-transfers",
      operation_id: "startPayment",
      summary: "Создание выплаты",
      responses: {}
    )
    original = operation.to_h

    expect(rules.score(operation, :create_request)[:score]).to be_positive
    expect(operation.to_h).to eq(original)
  end

  it "rejects roles outside the Space Payments contract" do
    expect { rules.score(operations.first, :refund) }.to raise_error(ArgumentError, /unknown operation role/)
  end
end
