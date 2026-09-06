# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Verification::Runtime do
  subject(:runtime) { described_class.new }

  it "loads and instantiates the BaseService subclass" do
    result = runtime.load(generated_integration)

    expect(result).to be_success
    expect(result.value["service_class"]).to be < result.value["fake_base_service"]
    expect(result.value["service"]).to be_a(result.value["service_class"])
  end

  it "provides deterministic fake credentials and operations" do
    context = runtime.load(generated_integration).value
    operation = runtime.build_operation(amount: 12, id: "op", provider_operation_key: "provider", payout_requisite: {})

    expect(context["credentials"].api_key).to eq("test-api-key")
    expect(operation.amount).to eq(12)
    expect(operation.provider_operation_key).to eq("provider")
    expect(operation).not_to respond_to(:provider_operation_id)
  end

  it "queues responses and records the renderer client-call shape" do
    context = runtime.load(generated_integration).value
    response = runtime.build_response(status: 201, body: { "id" => "p1" })
    context["client"].enqueue_response(response)

    returned = context["client"].post("/items", headers: { "X" => "1" }, body: { "a" => 1 })

    expect(returned).to equal(response)
    expect(context["client"].last_call).to eq(
      "method" => "POST", "path" => "/items", "args" => [],
      "kwargs" => { headers: { "X" => "1" }, body: { "a" => 1 } }
    )
  end

  it "records approve and reject actions" do
    service = runtime.load(generated_integration).value["service"]

    service.approve_operation("one")
    service.reject_operation("two", error: "bad")

    expect(service.actions.map { |item| item["type"] }).to eq(%w[approve reject])
  end

  it "models the official success result and positional failure contract" do
    service = runtime.load(generated_integration).value["service"]

    expect(service.success(result: { id: "provider" })).to include(
      "success" => true, "result" => { id: "provider" }
    )
    expect(service.failure(:bad_request, "errors.bad_request", field: "amount")).to include(
      "success" => false, "code" => :bad_request, "message" => "errors.bad_request",
      "data" => { field: "amount" }
    )
  end

  it "defines only the two confirmed provider exception classes alongside the generated service" do
    provider = runtime.load(generated_integration).value["provider"]

    expect(provider.const_get(:UnauthorizedError).new).to be_a(StandardError)
    expect(provider.const_get(:RateLimitError).new).to be_a(StandardError)
    expect(provider.constants(false)).to contain_exactly(:BaseService, :RateLimitError, :UnauthorizedError, :TestService)
  end

  it "reports source load errors" do
    result = runtime.load(generated_integration(source: "class Broken <\n"))

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("generated_service_load_error")
  end

  it "reports no service subclass" do
    result = runtime.load(generated_integration(source: "class Plain; end\n"))

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("generated_service_class_not_found")
  end

  it "reports ambiguous service subclasses" do
    source = "class One < Provider::BaseService; end\nclass Two < Provider::BaseService; end\n"
    result = runtime.load(generated_integration(source: source))

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("generated_service_class_ambiguous")
  end

  it "reports instantiation errors" do
    source = "class Bad < Provider::BaseService; def initialize(client:, credentials:); raise 'bad'; end; end\n"
    result = runtime.load(generated_integration(source: source))

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("generated_service_instantiation_error")
  end

  it "isolates constants between loads" do
    first = runtime.load(generated_integration(source: valid_service_source(class_name: "SameService")))
    second = runtime.load(generated_integration(source: valid_service_source(class_name: "SameService")))

    expect(first).to be_success
    expect(second).to be_success
    expect(first.value["sandbox"]).not_to equal(second.value["sandbox"])
    expect(first.value["service_class"]).not_to equal(second.value["service_class"])
  end
end
