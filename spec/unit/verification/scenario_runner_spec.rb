# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Verification::ScenarioRunner do
  subject(:runner) { described_class.new }

  it "executes create, all status outcomes, callbacks, 401, and 429 for synthetic Orbit" do
    result = runner.call(
      generated_integration: generated_orbit,
      mapping_plan: orbit_mapping_plan,
      provider_spec: synthetic_provider_spec
    )

    expect(result).to be_success
    expect(result.value).to include(
      "check_conditions" => "passed",
      "create_request" => "passed",
      "fetch_status_approved" => "passed",
      "fetch_status_rejected" => "passed",
      "fetch_status_in_progress" => "passed",
      "callback_approved" => "passed",
      "callback_rejected" => "passed",
      "callback_in_progress" => "passed",
      "unauthorized" => "passed",
      "rate_limit" => "passed"
    )
  end


  it "verifies both NovaPay requisite variants and platform failure codes" do
    result = runner.call(
      generated_integration: generated_novapay,
      mapping_plan: novapay_mapping_plan,
      provider_spec: novapay_provider_spec
    )

    expect(result.value).to include(
      "create_request" => "passed",
      "create_request_card" => "passed",
      "bad_request" => "passed",
      "unauthorized" => "passed",
      "rate_limit" => "passed",
      "validation_error" => "passed",
      "provider_error" => "passed",
      "idempotency" => "passed",
      "identifier_type_coercion" => "passed"
    )
  end

  it "uses stable operation.id idempotency and rejects an unselectable request variant" do
    runtime = ProviderCompiler::Verification::Runtime.new
    context = runtime.load(generated_novapay).value
    fixtures = JSON.parse(generated_novapay.fixtures_json)
    operation = runtime.build_operation(**fixtures.dig("create_request", "operation").transform_keys(&:to_sym))
    2.times do
      context["client"].enqueue_response(
        runtime.build_response(status: 201, body: fixtures.dig("create_request", "provider_response"))
      )
      context["service"].create_request(operation)
    end

    expect(context["client"].calls.map { |call| call.dig("kwargs", :headers, "Idempotency-Key") })
      .to eq([operation.id.to_s, operation.id.to_s])
    invalid = runtime.build_operation(amount: 100_000, id: "empty", payout_requisite: {})
    expect(context["service"].check_conditions(invalid)).to include(
      "success" => false, "code" => :bad_request
    )
  end


  it "skips a callback outcome when no compatible required event exists" do
    provider = input_provider_spec("04_polaris_pay_ambiguous_operations.yaml")
    override = SpecPaths.fixture("overrides", "polaris_operations_overrides.yml")
    plan = ProviderCompiler::Mapping::Mapper.new.call(provider, overrides: override).value
    integration = ProviderCompiler::Generation::ServiceGenerator.new.call(
      mapping_plan: plan, provider_spec: provider
    ).value

    result = runner.call(
      generated_integration: integration,
      mapping_plan: plan,
      provider_spec: provider
    )

    expect(result).to be_success
    expect(result.value).to include(
      "callback_approved" => "passed",
      "callback_rejected" => "passed",
      "callback_in_progress" => "skipped"
    )
  end

  it "returns create result.id without mutating provider_operation_key" do
    runtime = ProviderCompiler::Verification::Runtime.new
    context = runtime.load(generated_novapay).value
    fixtures = JSON.parse(generated_novapay.fixtures_json)
    card = fixtures.dig("create_request", "variants", "card")
    operation = runtime.build_operation(**card["operation"].transform_keys(&:to_sym))
    context["client"].enqueue_response(
      runtime.build_response(status: 201, body: fixtures.dig("create_request", "provider_response"))
    )

    outcome = context["service"].create_request(operation)

    expect(context["client"].last_call.dig("kwargs", :body, "recipient")).to eq(
      "type" => "card", "card_number" => "4111111111111111"
    )
    expect(outcome.dig("result", :id)).to eq("np_7f3a9b2c")
    expect(operation.provider_operation_key).to be_nil
  end

  it "uses provider_operation_key in fetch status URLs" do
    runtime = ProviderCompiler::Verification::Runtime.new
    context = runtime.load(generated_novapay).value
    operation = runtime.build_operation(provider_operation_key: "provider-42")
    context["client"].enqueue_response(runtime.build_response(status: 200, body: { "status" => "pending" }))

    context["service"].fetch_status(operation)

    expect(context["client"].last_call["path"]).to eq("https://api.sandbox.novapay.example/v1/payouts/provider-42")
  end

  it "maps amount_limit_exceeded to unprocessable_entity" do
    runtime = ProviderCompiler::Verification::Runtime.new
    context = runtime.load(generated_novapay).value
    fixtures = JSON.parse(generated_novapay.fixtures_json)
    operation = runtime.build_operation(**fixtures.dig("create_request", "operation").transform_keys(&:to_sym))
    context["client"].enqueue_response(
      runtime.build_response(
        status: 402,
        body: { "error" => { "code" => "amount_limit_exceeded", "message" => "limit" } }
      )
    )

    outcome = context["service"].create_request(operation)

    expect(outcome).to include("success" => false, "code" => :unprocessable_entity)
  end

  it "maps 404 and 409 to unprocessable_entity while preserving provider details" do
    runtime = ProviderCompiler::Verification::Runtime.new
    fixtures = JSON.parse(generated_novapay.fixtures_json)
    [404, 409].each do |status|
      context = runtime.load(generated_novapay).value
      attributes = fixtures.dig("create_request", "operation").transform_keys(&:to_sym)
      attributes[:provider_operation_key] = "provider-404" if status == 404
      operation = runtime.build_operation(**attributes)
      context["client"].enqueue_response(
        runtime.build_response(status: status, body: { "error" => { "code" => "provider_#{status}", "message" => "detail" } })
      )
      outcome = status == 404 ? context["service"].fetch_status(operation) : context["service"].create_request(operation)
      expect(outcome).to include("success" => false, "code" => :unprocessable_entity)
      expect(outcome["data"]).to include(provider_code: "provider_#{status}", provider_message: "detail")
    end
  end

  it "rejects missing provider identifiers at runtime" do
    runtime = ProviderCompiler::Verification::Runtime.new
    context = runtime.load(generated_novapay).value
    fixtures = JSON.parse(generated_novapay.fixtures_json)
    operation = runtime.build_operation(**fixtures.dig("create_request", "operation").transform_keys(&:to_sym))

    context["client"].enqueue_response(runtime.build_response(status: 201, body: {}))
    create_outcome = context["service"].create_request(operation)
    expect(create_outcome).to include("success" => false, "code" => :internal_server_error)

    context["service"].reset_actions!
    callback_outcome = context["service"].process_callback("status" => "completed")
    expect(callback_outcome).to include("success" => false, "code" => :unprocessable_entity)
    expect(context["service"].actions).to be_empty

    context["client"].reset!
    fetch_operation = runtime.build_operation(provider_operation_key: nil)
    fetch_outcome = context["service"].fetch_status(fetch_operation)
    expect(fetch_outcome).to include("success" => false, "code" => :bad_request)
    expect(context["client"].calls).to be_empty
  end

  it "executes the generated NovaPay service without network access" do
    result = runner.call(
      generated_integration: generated_novapay,
      mapping_plan: novapay_mapping_plan,
      provider_spec: novapay_provider_spec
    )

    expect(result).to be_success
    expect(result.value.values).not_to include("failed")
    expect(result.value["validation_error"]).to eq("passed")
    expect(result.value["provider_error"]).to eq("passed")
  end

  it "reports an HTTP method mismatch as blocking" do
    integration = generated_orbit
    broken = generated_integration(
      source: integration.service_code.sub("client.post(url", "client.get(url"),
      fixtures: integration.fixtures_json,
      filename: integration.service_filename
    )
    result = runner.call(generated_integration: broken, mapping_plan: orbit_mapping_plan)

    expect(result).to be_failure
    expect(result.value["create_request"]).to eq("failed")
    expect(result.diagnostics.map(&:code)).to include("scenario_http_method_mismatch")
  end

  it "reports an HTTP path mismatch as blocking" do
    integration = generated_orbit
    broken = generated_integration(
      source: integration.service_code.sub('url = "/transfers"', 'url = "/wrong"'),
      fixtures: integration.fixtures_json
    )
    result = runner.call(generated_integration: broken, mapping_plan: orbit_mapping_plan)

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("scenario_http_path_mismatch")
  end

  it "reports a mapped request body mismatch" do
    integration = generated_orbit
    broken = generated_integration(
      source: integration.service_code.sub('"sum" =>', '"different" =>'),
      fixtures: integration.fixtures_json
    )
    result = runner.call(generated_integration: broken, mapping_plan: orbit_mapping_plan)

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("scenario_request_body_mismatch")
  end

  it "reports a security mismatch" do
    integration = generated_orbit
    broken = generated_integration(
      source: integration.service_code.sub('headers["X-Partner-Token"] =', 'headers["Wrong"] ='),
      fixtures: integration.fixtures_json
    )
    result = runner.call(generated_integration: broken, mapping_plan: orbit_mapping_plan)

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("scenario_security_mismatch")
  end

  it "marks unavailable provider error scenarios skipped" do
    result = runner.call(generated_integration: generated_orbit, mapping_plan: orbit_mapping_plan)

    expect(result.value["validation_error"]).to eq("skipped")
    expect(result.value["provider_error"]).to eq("skipped")
  end

  it "keeps the webhook HMAC limitation non-blocking" do
    result = runner.call(generated_integration: generated_orbit, mapping_plan: orbit_mapping_plan)

    expect(result).to be_success
    expect(result.value["webhook_signature"]).to eq("skipped")
    warning = result.diagnostics.find { |item| item.code == "webhook_signature_runtime_unavailable" }
    expect(warning).to be_warning
    expect(warning).not_to be_blocking
  end
end
