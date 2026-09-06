# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "support"

RSpec.describe ProviderCompiler::Generation::FixturesGenerator do
  subject(:generator) { described_class.new }

  let(:plan) { novapay_mapping_plan }
  let(:fixtures) { generator.generate(mapping_plan: plan, provider_spec: novapay_provider_spec) }

  it "returns a deterministic JSON-serializable Hash" do
    expect(fixtures).to be_a(Hash)
    expect(fixtures.keys).to eq(%w[create_request fetch_status callbacks errors])
    expect { JSON.generate(fixtures) }.not_to raise_error
    expect(generator.generate(mapping_plan: plan, provider_spec: novapay_provider_spec)).to eq(fixtures)
  end

  it "builds provider requests from schema examples and mapped operation fields" do
    create = fixtures.fetch("create_request")

    expect(create.dig("operation", "amount")).to eq(15_000)
    expect(create.dig("provider_request", "amount")).to eq(1_500_000)
    expect(create.dig("provider_request", "currency")).to eq("RUB")
    expect(create.dig("provider_request", "external_id")).to eq("op_abc123")
    expect(create.dig("provider_request", "recipient", "phone")).to eq("79001234567")
    expect(create.dig("operation", "payout_requisite", "sbp", "phone")).to eq("79001234567")
    expect(create.dig("provider_request", "recipient", "type")).to eq("sbp")
    expect(create.dig("variants", "card", "operation", "payout_requisite", "card_number")).to eq("4111111111111111")
    expect(create.dig("variants", "card", "provider_request", "recipient")).to eq(
      "type" => "card", "card_number" => "4111111111111111"
    )
    expect(create.dig("provider_response", "id")).to eq("np_7f3a9b2c")
  end

  it "creates status callbacks and mapped error fixtures" do
    expect(fixtures.fetch("callbacks").keys).to contain_exactly("approved", "rejected", "in_progress")
    expect(fixtures.dig("callbacks", "approved", "status")).to eq("completed")
    expect(fixtures.dig("callbacks", "approved", "event")).to eq("payout.completed")
    expect(fixtures.dig("errors", "unauthorized", "http_status")).to eq(401)
    expect(fixtures.dig("errors", "too_many_requests", "http_status")).to eq(429)
    expect(fixtures.dig("errors", "too_many_requests", "headers", "Retry-After")).to eq("60")
    expect(fixtures.fetch("errors")).to include("bad_request", "unprocessable_entity", "internal_server_error")
  end

  it "supports nested provider paths without exposing credentials" do
    json = JSON.generate(fixtures)

    expect(json).not_to include("X-API-Key", "webhook_secret", "api_key")
    expect(json).not_to match(/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}/i)
  end


  it "omits callbacks when a required event has no compatible internal outcome" do
    provider = input_provider_spec("04_polaris_pay_ambiguous_operations.yaml")
    override = SpecPaths.fixture("overrides", "polaris_operations_overrides.yml")
    mapping_plan = ProviderCompiler::Mapping::Mapper.new.call(provider, overrides: override).value

    callbacks = generator.generate(mapping_plan: mapping_plan, provider_spec: provider).fetch("callbacks")

    expect(callbacks.keys).to contain_exactly("approved", "rejected")
    expect(callbacks.dig("approved", "event")).to eq("operation.completed")
    expect(callbacks.dig("approved", "status")).to eq("completed")
    expect(callbacks.dig("rejected", "event")).to eq("operation.failed")
    expect(callbacks.dig("rejected", "status")).to eq("failed")
    expect(callbacks).not_to have_key("in_progress")
  end
end
