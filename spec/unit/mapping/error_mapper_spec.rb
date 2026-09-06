# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::ErrorMapper do
  subject(:mapper) { described_class.new }

  it "maps standard HTTP errors and preserves Retry-After" do
    provider_spec = synthetic_provider_spec
    create = provider_spec.operations.first
    mappings = mapper.call(provider_spec: provider_spec, operation_matches: { "create_request" => create })

    expect(mappings.find { |item| item.http_status == "401" }.target).to eq("unauthorized")
    rate_limit = mappings.find { |item| item.http_status == "429" }
    expect(rate_limit.target).to eq("too_many_requests")
    expect(rate_limit).to be_retryable
    expect(rate_limit.retry_after_header).to eq("Retry-After")
  end

  it "maps every HTTP failure to the platform whitelist" do
    operation = api_operation(
      method: :post,
      path: "/transfers",
      responses: {
        "400" => api_response(400),
        "402" => api_response(402, description: "Insufficient provider balance"),
        "403" => api_response(403),
        "404" => api_response(404),
        "422" => api_response(422),
        "500" => api_response(500)
      }
    )
    mappings = mapper.call(provider_spec: synthetic_provider_spec, operation_matches: { "create_request" => operation })

    expect(mappings.to_h { |item| [item.http_status, item.target] }).to include(
      "400" => "bad_request", "402" => "unprocessable_entity", "403" => "forbidden",
      "404" => "unprocessable_entity", "422" => "unprocessable_entity", "500" => "internal_server_error"
    )
  end

  it "maps amount_limit_exceeded to unprocessable_entity policy" do
    error_schema = api_schema(
      type: "object",
      properties: {
        "error" => api_schema(
          type: "object",
          properties: { "code" => api_schema(type: "string", enum: ["amount_limit_exceeded"]) }
        )
      }
    )
    operation = api_operation(
      method: :post,
      path: "/transfers",
      responses: { "402" => api_response(402, schema: error_schema, description: "Business error") }
    )

    mapping = mapper.call(provider_spec: synthetic_provider_spec, operation_matches: { "create_request" => operation }).first

    expect(mapping.metadata.dig("provider_code_targets", "amount_limit_exceeded")).to eq("unprocessable_entity")
  end

  it "keeps provider code details without overriding the HTTP status policy" do
    error_schema = api_schema(
      type: "object",
      properties: {
        "error" => api_schema(
          type: "object",
          properties: { "code" => api_schema(type: "string", enum: ["amount_limit_exceeded"]) }
        )
      }
    )
    operation = api_operation(
      method: :post, path: "/transfers",
      responses: { "400" => api_response(400, schema: error_schema) }
    )

    mapping = mapper.call(
      provider_spec: synthetic_provider_spec, operation_matches: { "create_request" => operation }
    ).first

    expect(mapping.target).to eq("bad_request")
    expect(mapping.metadata.dig("provider_code_targets", "amount_limit_exceeded")).to eq("bad_request")
  end

  it "preserves 409 provider semantics without exposing custom platform codes" do
    duplicate = api_operation(
      method: :post,
      path: "/transfers",
      summary: "Create transfer",
      responses: { "409" => api_response(409, description: "Duplicate idempotency key") }
    )
    invalid = api_operation(
      method: :post,
      path: "/transfers/{id}/cancel",
      summary: "Cancel transfer",
      responses: { "409" => api_response(409, description: "Cannot cancel in current status") }
    )
    mappings = mapper.call(
      provider_spec: synthetic_provider_spec,
      operation_matches: { "create_request" => duplicate, "cancel" => invalid }
    )

    expect(mappings.map(&:target)).to eq(%w[unprocessable_entity unprocessable_entity])
  end

  it "marks generic 409 for review and detects nested code/message paths" do
    error_schema = api_schema(
      type: "object",
      properties: {
        "error" => api_schema(
          type: "object",
          properties: {
            "code" => api_schema(type: "string", enum: ["conflict"]),
            "message" => api_schema(type: "string")
          }
        )
      }
    )
    operation = api_operation(method: :post, path: "/things", responses: { "409" => api_response(409, schema: error_schema) })
    mapping = mapper.call(provider_spec: synthetic_provider_spec, operation_matches: { "create_request" => operation }).first

    expect(mapping.target).to eq("unprocessable_entity")
    expect(mapping).to be_auto
    expect(mapping.provider_code_path).to eq("error.code")
    expect(mapping.message_path).to eq("error.message")
    expect(mapping.metadata["provider_codes"]).to eq(["conflict"])
    expect(mapping.metadata.dig("provider_code_targets", "conflict")).to eq("unprocessable_entity")
    expect(mapper.diagnostics).to be_empty
  end
end
