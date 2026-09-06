# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Verification::Verifier do
  subject(:verifier) { described_class.new }

  it "verifies the real NovaPay Loader-to-runtime pipeline" do
    result = verifier.call(
      generated_integration: generated_novapay,
      mapping_plan: novapay_mapping_plan,
      provider_spec: novapay_provider_spec
    )

    expect(result).to be_success
    expect(result.value.slice("syntax", "fixtures", "contract")).to eq(
      "syntax" => "passed", "fixtures" => "passed", "contract" => "passed"
    )
    expect(result.value["scenarios"].except("webhook_signature").values).to all(eq("passed"))
    expect(result.value.dig("scenarios", "webhook_signature")).to eq("skipped")
  end

  it "verifies synthetic Orbit generation at runtime without provider-specific assumptions" do
    result = verifier.call(
      generated_integration: generated_orbit,
      mapping_plan: orbit_mapping_plan,
      provider_spec: synthetic_provider_spec
    )

    expect(result).to be_success
    expect(result.value.values_at("syntax", "fixtures", "contract")).to eq(%w[passed passed passed])
    expect(result.value["scenarios"]).to include(
      "create_request" => "passed",
      "fetch_status_approved" => "passed",
      "callback_approved" => "passed"
    )
    expect(generated_orbit.service_code).to include('url = "/transfers"', 'url = "/transactions/#{operation.provider_operation_key}"')
    expect(orbit_mapping_plan.webhook.operation.path).to eq("/notifications")
  end

  it "does not load or execute after a syntax failure" do
    contract = double("contract_checker")
    scenarios = double("scenario_runner")
    allow(contract).to receive(:call)
    allow(scenarios).to receive(:call)
    verifier = described_class.new(contract_checker: contract, scenario_runner: scenarios)
    broken = generated_integration(source: "class Broken <\n")

    result = verifier.call(generated_integration: broken, mapping_plan: orbit_mapping_plan)

    expect(result).to be_failure
    expect(result.value).to include("syntax" => "failed", "fixtures" => "skipped", "contract" => "skipped")
    expect(contract).not_to have_received(:call)
    expect(scenarios).not_to have_received(:call)
  end

  it "skips scenarios after fixture failure while still checking the contract" do
    scenarios = double("scenario_runner")
    allow(scenarios).to receive(:call)
    verifier = described_class.new(scenario_runner: scenarios)
    broken = generated_integration(fixtures: "{}")

    result = verifier.call(generated_integration: broken, mapping_plan: orbit_mapping_plan)

    expect(result).to be_failure
    expect(result.value).to include("fixtures" => "failed", "contract" => "passed")
    expect(result.value["scenarios"].values).to all(eq("skipped"))
    expect(scenarios).not_to have_received(:call)
  end

  it "skips scenarios after contract failure" do
    scenarios = double("scenario_runner")
    allow(scenarios).to receive(:call)
    verifier = described_class.new(scenario_runner: scenarios)
    broken = generated_integration(
      source: "class EmptyService < Provider::BaseService; end\n",
      fixtures: generated_orbit.fixtures_json
    )

    result = verifier.call(generated_integration: broken, mapping_plan: orbit_mapping_plan)

    expect(result).to be_failure
    expect(result.value).to include("syntax" => "passed", "fixtures" => "passed", "contract" => "failed")
    expect(scenarios).not_to have_received(:call)
  end

  it "returns a deterministic report" do
    arguments = { generated_integration: generated_orbit, mapping_plan: orbit_mapping_plan }

    expect(verifier.call(**arguments).value).to eq(verifier.call(**arguments).value)
  end
end
