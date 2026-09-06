# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::FieldRules do
  subject(:rules) { described_class.new }

  def candidate(path, type: "string", description: nil, source: "request_body", location: nil)
    { path: path, schema: api_schema(type: type, description: description), source: source, location: location }
  end

  it "scores amount aliases, numeric types, and descriptions independently" do
    direct = rules.score(candidate("amount", type: "integer"), "operation.amount")
    described = rules.score(candidate("gross", type: "number", description: "Сумма в копейках"), "operation.amount")

    expect(direct[:score]).to be > described[:score]
    expect(described[:evidence].map { |item| item["rule"] }).to include("amount_numeric_type", "amount_description")
  end

  it "distinguishes client ids, provider ids, and whole requisite objects by context" do
    client = rules.score(candidate("reference_id"), "operation.id")
    provider = rules.score(candidate("transaction_id", source: "response"), "operation.provider_operation_key")
    requisite = rules.score(candidate("beneficiary", type: "object"), "operation.payout_requisite")

    expect(client[:score]).to be >= 50
    expect(provider[:score]).to be >= 50
    expect(requisite[:score]).to be >= 50
  end

  it "gives path parameters provider-id context and rejects invented internal fields" do
    result = rules.score(
      candidate("transaction_id", source: "parameter", location: "path"),
      "operation.provider_operation_key"
    )

    expect(result[:evidence].map { |item| item["rule"] }).to include("status_path_parameter")
    expect { rules.score(candidate("fee"), "operation.fee") }.to raise_error(ArgumentError)
  end

  it "recognizes merchant references only in client/request context" do
    merchant_reference = rules.score(candidate("merchant_reference"), "operation.id")
    merchant_order = rules.score(
      candidate("merchant_order_id", description: "Client merchant order identifier"),
      "operation.id"
    )
    ambiguous_order = rules.score(candidate("order_id"), "operation.id")

    expect(merchant_reference[:score]).to be >= 50
    expect(merchant_order[:score]).to be >= 50
    expect(ambiguous_order[:score]).to be < 30
  end

  it "recognizes provider order ids only with response/path context and description" do
    response = rules.score(
      candidate("order_id", description: "Provider payout order identifier", source: "response"),
      "operation.provider_operation_key"
    )
    path = rules.score(
      candidate(
        "order_id",
        description: "Provider-generated payout order id",
        source: "parameter",
        location: "path"
      ),
      "operation.provider_operation_key"
    )
    request = rules.score(candidate("order_id"), "operation.provider_operation_key")

    expect(response[:score]).to be >= 50
    expect(path[:score]).to be >= 50
    expect(request[:score]).to be < 30
  end

  it "recognizes snake_case and camelCase disbursement ids generically" do
    snake = rules.score(candidate("disbursement_id", source: "response"), "operation.provider_operation_key")
    camel = rules.score(candidate("disbursementId", source: "response"), "operation.provider_operation_key")

    expect(snake[:score]).to be >= 50
    expect(camel[:score]).to eq(snake[:score])
  end
end
