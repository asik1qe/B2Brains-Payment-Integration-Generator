# frozen_string_literal: true

require "json"
require_relative "../generation/support"

module VerificationSpecSupport
  def generated_integration(source: valid_service_source, fixtures: valid_fixtures, filename: "test_service.rb")
    ProviderCompiler::Core::GeneratedIntegration.new(
      service_code: source,
      integration_markdown: "# Test\n",
      fixtures_json: fixtures.is_a?(String) ? fixtures : JSON.pretty_generate(fixtures),
      service_filename: filename,
      provider_name: "Test",
      metadata: { "class_name" => "TestService", "qualified_class_name" => "Provider::TestService" }
    )
  end

  def valid_service_source(class_name: "TestService")
    <<~RUBY
      class Provider::#{class_name} < Provider::BaseService
        def check_conditions(operation, request_method = nil)
          success(result: operation)
        end

        def create_request(operation, request_method = nil)
          response = client.post("/items", headers: { "X-Key" => credentials.api_key }, body: { "amount" => operation.amount })
          success(result: { id: response.body["id"] })
        end

        def process_callback(payload)
          success(result: payload)
        end

        def fetch_status(operation)
          client.get("/items/\#{operation.provider_operation_key}", headers: {})
          success(result: operation)
        end
      end
    RUBY
  end

  def valid_fixtures
    {
      "create_request" => {
        "operation" => { "amount" => 10, "id" => "op-1", "payout_requisite" => { "account" => "123" } },
        "provider_request" => { "amount" => 10 },
        "provider_response" => { "id" => "provider-1", "status" => "queued" }
      },
      "fetch_status" => { "provider_response" => { "id" => "provider-1", "status" => "queued" } },
      "callbacks" => {},
      "errors" => {}
    }
  end

  def generated_novapay
    ProviderCompiler::Generation::ServiceGenerator.new.call(
      mapping_plan: novapay_mapping_plan,
      provider_spec: novapay_provider_spec
    ).value
  end

  def generated_orbit
    ProviderCompiler::Generation::ServiceGenerator.new.call(
      mapping_plan: orbit_mapping_plan,
      provider_spec: synthetic_provider_spec
    ).value
  end
end

RSpec.configure do |config|
  config.include VerificationSpecSupport
end
