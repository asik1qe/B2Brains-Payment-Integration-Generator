# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Verification::FixtureValidator do
  subject(:validator) { described_class.new }

  it "accepts the generated NovaPay golden fixtures against its MappingPlan" do
    fixtures = File.binread(SpecPaths.fixture("golden", "novapay", "fixtures.json"))
    result = validator.call(generated_integration(fixtures: fixtures), mapping_plan: novapay_mapping_plan)

    expect(result).to be_success
  end

  it "reports invalid JSON" do
    result = validator.call(generated_integration(fixtures: "{"))

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("fixtures_json_invalid")
  end

  it "rejects an array root" do
    result = validator.call(generated_integration(fixtures: "[]"))

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("fixtures_root_invalid")
  end

  it "reports each missing required section" do
    result = validator.call(generated_integration(fixtures: {}))

    expect(result).to be_failure
    expect(result.diagnostics.count { |item| item.code == "fixtures_structure_invalid" }).to eq(4)
  end

  it "rejects a callback provider status inconsistent with StatusMapping" do
    fixtures = JSON.parse(generated_novapay.fixtures_json)
    fixtures["callbacks"]["approved"]["status"] = "not-mapped"
    result = validator.call(generated_integration(fixtures: fixtures), mapping_plan: novapay_mapping_plan)

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("fixtures_mapping_inconsistent")
  end


  it "rejects a callback event that contradicts its internal outcome" do
    fixtures = JSON.parse(generated_novapay.fixtures_json)
    fixtures["callbacks"]["approved"]["event"] = "payout.failed"
    result = validator.call(generated_integration(fixtures: fixtures), mapping_plan: novapay_mapping_plan)

    expect(result).to be_failure
    expect(result.diagnostics.map(&:message)).to include(
      "Callback fixture approved is inconsistent with WebhookMapping events"
    )
  end

  it "rejects an error status absent from ErrorMappings" do
    fixtures = JSON.parse(generated_novapay.fixtures_json)
    fixtures["errors"]["unprocessable_entity"]["http_status"] = 418
    result = validator.call(generated_integration(fixtures: fixtures), mapping_plan: novapay_mapping_plan)

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("fixtures_mapping_inconsistent")
  end

  it "detects nested credential values" do
    fixtures = valid_fixtures
    fixtures["create_request"]["metadata"] = { "api_key" => "live-key-123" }
    result = validator.call(generated_integration(fixtures: fixtures))

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("fixture_contains_secret")
  end

  it "allows explicit test placeholders" do
    fixtures = valid_fixtures
    fixtures["create_request"]["metadata"] = { "api_key" => "test-api-key" }

    expect(validator.call(generated_integration(fixtures: fixtures))).to be_success
  end

  it "parses deterministically without mutating input" do
    integration = generated_integration(fixtures: valid_fixtures)
    first = validator.call(integration)
    second = validator.call(integration)

    expect(first.value).to eq(second.value)
    expect(first.diagnostics).to eq(second.diagnostics)
  end
end
