# frozen_string_literal: true

require "spec_helper"

RSpec.describe "generated runtime pipeline" do
  def parsed(path)
    loaded = ProviderCompiler::OpenAPI::Loader.new.call(path)
    expect(loaded).to be_success
    parsed = ProviderCompiler::OpenAPI::Parser.new.call(loaded.value)
    expect(parsed).to be_success
    parsed.value
  end

  def generated(spec_path, overrides: nil, provider_name: "runtime_provider")
    provider_spec = parsed(spec_path)
    mapped = ProviderCompiler::Mapping::Mapper.new.call(provider_spec, overrides: overrides)
    expect(mapped).to be_success
    # ServiceGenerator receives provider_name from the plan in normal Compiler flow.
    # Rebuild the plan here only to exercise an arbitrary generated provider name.
    plan = ProviderCompiler::Core::Mapping::MappingPlan.new(
      provider_name: provider_name,
      operations: mapped.value.operations,
      fields: mapped.value.fields,
      statuses: mapped.value.statuses,
      errors: mapped.value.errors,
      security: mapped.value.security,
      webhook: mapped.value.webhook,
      conditions: mapped.value.conditions,
      diagnostics: mapped.value.diagnostics,
      metadata: mapped.value.metadata
    )
    generation = ProviderCompiler::Generation::ServiceGenerator.new.call(
      mapping_plan: plan,
      provider_spec: provider_spec
    )
    expect(generation).to be_success
    [provider_spec, plan, generation.value]
  end

  it "loads the generated NovaPay class and satisfies the BaseService contract" do
    _provider_spec, plan, integration = generated(
      SpecPaths.fixture("official", "novapay_provider_api.yaml"),
      provider_name: "runtime_novapay"
    )
    runtime = ProviderCompiler::Verification::Runtime.new
    loaded = runtime.load(integration)

    expect(loaded).to be_success
    provider = loaded.value.fetch("provider")
    expected_class = provider.const_get(:RuntimeNovapayService, false)
    expect(loaded.value.fetch("service")).to be_a(expected_class)
    expect(loaded.value.fetch("service_class")).to equal(expected_class)
    checked = ProviderCompiler::Verification::ContractChecker.new.call(integration)
    expect(checked).to be_success
    expect(plan.metadata).to be_a(Hash)
  end

  it "verifies idempotency, request variants, callbacks, statuses, and platform errors in one runtime pass" do
    provider_spec, plan, integration = generated(
      SpecPaths.fixture("official", "novapay_provider_api.yaml"),
      provider_name: "runtime_matrix"
    )
    verification = ProviderCompiler::Verification::Verifier.new.call(
      generated_integration: integration,
      mapping_plan: plan,
      provider_spec: provider_spec
    )

    expect(verification).to be_success
    scenarios = verification.value.fetch("scenarios")
    %w[
      check_conditions create_request create_request_card idempotency
      fetch_status_in_progress fetch_status_approved fetch_status_rejected
      callback_in_progress callback_approved callback_rejected
      bad_request unauthorized validation_error rate_limit
    ].each do |name|
      expect(scenarios.fetch(name)).to eq("passed"), "scenario #{name} was #{scenarios[name].inspect}"
    end
  end

  it "keeps create, fetch, and callback status paths independent for nested providers" do
    provider_spec, plan, integration = generated(
      SpecPaths.fixture("synthetic", "08_riverpay_bearer_query_nested.yaml"),
      provider_name: "runtime_river"
    )
    source = integration.service_code

    expect(source).to include('provider_status = dig_value(payload, "data.state")')
    expect(plan.webhook.status_path).not_to eq("data.state")
    verification = ProviderCompiler::Verification::Verifier.new.call(
      generated_integration: integration,
      mapping_plan: plan,
      provider_spec: provider_spec
    )
    expect(verification).to be_success
  end
end
