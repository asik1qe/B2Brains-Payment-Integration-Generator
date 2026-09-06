# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::OpenAPI::Parser do
  let(:document) do
    {
      openapi: "3.0.3",
      info: { title: "Payments API", description: "Provider facts", version: "1.2" },
      servers: [{ url: "https://api.example.test", description: "Sandbox", :"x-region" => "eu" }],
      security: [{ ApiKeyAuth: [] }],
      tags: [{ name: "Payouts" }],
      :"x-document" => false,
      components: {
        schemas: {
          Payment: {
            type: "object", required: ["amount"],
            properties: { amount: { type: "integer", minimum: 100 } }
          }
        },
        parameters: {
          ItemId: {
            name: "id", in: "path", required: true,
            schema: { type: "string" }, description: "Path-level"
          }
        },
        requestBodies: {
          PaymentBody: {
            required: true,
            content: {
              "application/json" => {
                schema: { "$ref" => "#/components/schemas/Payment" },
                example: { amount: 100 }
              }
            }
          }
        },
        headers: {
          Trace: { description: "Trace header", schema: { type: "string" } }
        },
        responses: {
          Created: {
            description: "Created",
            headers: { "X-Trace" => { "$ref" => "#/components/headers/Trace" } },
            content: {
              "application/problem+json" => {
                schema: { "$ref" => "#/components/schemas/Payment" },
                examples: { sample: { value: { amount: 100 } } }
              }
            }
          }
        },
        securitySchemes: {
          ApiKeyAuth: { type: "apiKey", in: "header", name: "X-API-Key" },
          BearerAuth: { type: "http", scheme: "bearer", bearerFormat: "JWT" }
        }
      },
      paths: {
        "/items/{id}" => {
          parameters: [{ "$ref" => "#/components/parameters/ItemId" }],
          get: {
            operationId: "GetItem", tags: ["Payouts"],
            responses: { "200" => { "$ref" => "#/components/responses/Created" } },
            :"x-operation" => "get"
          },
          post: {
            operationId: "CreateItem",
            parameters: [
              {
                name: "id", in: "PATH", required: true,
                schema: { type: "string" }, description: "Operation override"
              },
              { name: "dry_run", in: "query", schema: { type: "boolean" } }
            ],
            requestBody: { "$ref" => "#/components/requestBodies/PaymentBody" },
            responses: {
              201 => { "$ref" => "#/components/responses/Created" },
              default: { description: "Unexpected" }
            },
            security: []
          }
        }
      }
    }
  end

  subject(:result) { described_class.new.call(document) }

  it "builds ProviderSpec metadata, servers, tags, and extensions" do
    spec = result.value

    expect(result).to be_success
    expect(spec.openapi_version).to eq("3.0.3")
    expect(spec.title).to eq("Payments API")
    expect(spec.description).to eq("Provider facts")
    expect(spec.api_version).to eq("1.2")
    expect(spec.servers.first.url).to eq("https://api.example.test")
    expect(spec.tags).to eq([{ "name" => "Payouts" }])
    expect(spec.extensions).to eq("x-document" => false)
  end

  it "parses standard HTTP methods into operations" do
    spec = result.value

    expect(spec.operations.map { |operation| [operation.http_method, operation.path] }).to eq(
      [["GET", "/items/{id}"], ["POST", "/items/{id}"]]
    )
    expect(spec.operation(http_method: :get, path: "/items/{id}").operation_id).to eq("GetItem")
  end

  it "merges path and operation parameters with operation-level override" do
    operation = result.value.operation(http_method: :post, path: "/items/{id}")

    expect(operation.parameters.size).to eq(2)
    expect(operation.parameter("id", location: :path).description).to eq("Operation override")
    expect(operation.parameter("dry_run", location: :query).schema.type).to eq("boolean")
  end

  it "parses request bodies, JSON-suffix responses, examples, and reusable schemas" do
    operation = result.value.operation(http_method: :post, path: "/items/{id}")

    expect(operation.request_body.required).to be(true)
    expect(operation.request_body.content_type).to eq("application/json")
    expect(operation.request_body.schema.ref).to eq("#/components/schemas/Payment")
    expect(operation.request_body.examples).to eq("default" => { "amount" => 100 })

    response = operation.response(201)
    expect(response.content_type).to eq("application/problem+json")
    expect(response.schema.name).to eq("Payment")
    expect(response.examples).to have_key("sample")
    expect(operation.response("default").description).to eq("Unexpected")
  end

  it "parses reusable response headers as header Parameters" do
    response = result.value.operation(http_method: :post, path: "/items/{id}").response(201)
    header = response.header("x-trace")

    expect(header.name).to eq("X-Trace")
    expect(header).to be_header
    expect(header.required).to be(false)
    expect(header.schema.type).to eq("string")
  end

  it "parses component schemas and security schemes" do
    spec = result.value

    expect(spec.schema(:Payment).name).to eq("Payment")
    expect(spec.schema(:Payment).property(:amount).minimum).to eq(100)
    expect(spec.security_scheme(:ApiKeyAuth)).to be_api_key
    expect(spec.security_scheme(:ApiKeyAuth).name).to eq("X-API-Key")
    expect(spec.security_scheme(:BearerAuth)).to be_bearer
    expect(spec.security_scheme(:BearerAuth).bearer_format).to eq("JWT")
  end

  it "preserves global and operation security nil separately from empty arrays" do
    spec = result.value
    get = spec.operation(http_method: :get, path: "/items/{id}")
    post = spec.operation(http_method: :post, path: "/items/{id}")

    expect(spec.global_security).to eq([{ "ApiKeyAuth" => [] }])
    expect(get.security).to be_nil
    expect(post.security).to eq([])

    absent = described_class.new.call("openapi" => "3.0.3").value
    empty = described_class.new.call("openapi" => "3.0.3", "security" => []).value
    expect(absent.global_security).to be_nil
    expect(empty.global_security).to eq([])
  end

  it "retains non-JSON content facts and emits a non-blocking policy warning" do
    document = {
      "openapi" => "3.0.3",
      "paths" => {
        "/upload" => {
          "post" => {
            "requestBody" => {
              "content" => { "text/plain" => { "schema" => { "type" => "string" } } }
            },
            "responses" => {}
          }
        }
      }
    }
    parsed = described_class.new.call(document)

    expect(parsed).to be_success
    expect(parsed).to be_needs_review
    expect(parsed.value.operations.first.request_body.content_type).to eq("text/plain")
    expect(parsed.diagnostics.map(&:code)).to include("non_json_content_unsupported")
  end

  it "returns a partial failure for unsupported versions and nil for invalid documents" do
    unsupported = described_class.new.call("openapi" => "3.1.0")
    invalid = described_class.new.call([])

    expect(unsupported).to be_failure
    expect(unsupported.value.openapi_version).to eq("3.1.0")
    expect(invalid).to be_failure
    expect(invalid.value).to be_nil
  end

  it "extracts extensions for every supported core object" do
    schema = result.value.schema(:Payment)
    operation = result.value.operation(http_method: :get, path: "/items/{id}")

    expect(result.value.extensions).to eq("x-document" => false)
    expect(result.value.servers.first.extensions).to eq("x-region" => "eu")
    expect(operation.extensions).to eq("x-operation" => "get")
    expect(schema.extensions).to eq({})
  end

  it "preserves effective path and operation server provenance" do
    parsed = described_class.new.call(
      "openapi" => "3.0.3",
      "servers" => [{ "url" => "https://root.example" }],
      "paths" => {
        "/items" => {
          "servers" => [{ "url" => "https://path.example" }],
          "post" => { "responses" => {}, "servers" => [{ "url" => "https://operation.example" }] },
          "get" => { "responses" => {} }
        }
      }
    )

    post = parsed.value.operation(http_method: :post, path: "/items")
    get = parsed.value.operation(http_method: :get, path: "/items")
    expect([post.server_source, post.servers.first.url]).to eq(["operation", "https://operation.example"])
    expect([get.server_source, get.servers.first.url]).to eq(["path", "https://path.example"])
  end

  describe "official NovaPay provider_api.yaml" do
    let(:fixture_path) { SpecPaths.fixture("official", "novapay_provider_api.yaml") }
    let(:loaded) { ProviderCompiler::OpenAPI::Loader.new.call(fixture_path) }
    let(:parsed) { described_class.new.call(loaded.value) }
    let(:provider_spec) { parsed.value }

    it "loads and parses the real document without diagnostics" do
      expect(loaded).to be_success
      expect(parsed).to be_success
      expect(parsed.diagnostics).to be_empty
      expect(provider_spec.openapi_version).to eq("3.0.3")
      expect(provider_spec.title).to eq("NovaPay Payout API")
      expect(provider_spec.api_version).to eq("1.0.0")
      expect(provider_spec.servers.map { |server| [server.url, server.description] }).to eq(
        [
          ["https://api.sandbox.novapay.example/v1", "Sandbox"],
          ["https://api.novapay.example/v1", "Production"]
        ]
      )
    end

    it "builds all five real provider operations without mapping semantics" do
      expect(provider_spec.operations.map { |operation| [operation.http_method, operation.path] }).to contain_exactly(
        ["POST", "/payouts"],
        ["GET", "/payouts/{payout_id}"],
        ["POST", "/payouts/{payout_id}/cancel"],
        ["POST", "/webhooks/payout"],
        ["GET", "/balance"]
      )
      expect(provider_spec.operations.size).to eq(5)
      expect(provider_spec).not_to respond_to(:create_request, :approved, :operation_amount)
    end

    it "preserves the API key and payout component schemas" do
      api_key = provider_spec.security_scheme(:ApiKeyAuth)
      create_request = provider_spec.schema(:CreatePayoutRequest)
      recipient = provider_spec.schema(:Recipient)
      payout_response = provider_spec.schema(:PayoutResponse)

      expect(api_key).to be_api_key
      expect(api_key.location).to eq("header")
      expect(api_key.name).to eq("X-API-Key")

      expect(provider_spec.schemas.keys).to include("CreatePayoutRequest", "Recipient", "PayoutResponse")
      expect(create_request.required).to contain_exactly("amount", "currency", "external_id", "recipient")
      expect(create_request.property(:amount).minimum).to eq(100_000)
      expect(create_request.property(:amount).description).to include("копейках")
      expect(create_request.property(:currency).enum).to eq(["RUB"])
      expect(create_request.property(:recipient).ref).to eq("#/components/schemas/Recipient")

      expect(recipient.required).to contain_exactly("type", "phone")
      expect(recipient.property(:phone).pattern).to eq('^7\d{10}$')
      expect(recipient.property(:bank_code).description).to include("БИК банка")
      expect(payout_response.property(:status).enum).to eq(
        %w[pending processing completed failed cancelled]
      )
    end

    it "parses the create-payout request, idempotency header, and all responses" do
      operation = provider_spec.operation(http_method: :post, path: "/payouts")
      idempotency_key = operation.parameter("Idempotency-Key", location: :header)

      expect(operation.request_body.required).to be(true)
      expect(operation.request_body.content_type).to eq("application/json")
      expect(operation.request_body.schema.ref).to eq("#/components/schemas/CreatePayoutRequest")
      expect(operation.request_body.schema.name).to eq("CreatePayoutRequest")

      expect(idempotency_key.required).to be(false)
      expect(idempotency_key.schema.type).to eq("string")
      expect(idempotency_key.schema.format).to eq("uuid")
      expect(operation.responses.keys).to contain_exactly("201", "400", "401", "402", "409", "422", "429", "500")
      expect(operation.response(201).schema.name).to eq("PayoutResponse")
      expect(operation.response(422).schema.name).to eq("ErrorResponse")

      retry_after = operation.response(429).header("retry-after")
      expect(retry_after.name).to eq("Retry-After")
      expect(retry_after.schema.type).to eq("integer")
      expect(retry_after.description).to include("повторной попытки")
    end

    it "preserves webhook security, signature header, statuses, and events" do
      webhook = provider_spec.operation(http_method: :post, path: "/webhooks/payout")
      signature = webhook.parameter("X-NovaPay-Signature", location: :header)
      payload = webhook.request_body.schema

      expect(webhook.security).to eq([])
      expect(webhook).to be_security_disabled
      expect(signature.required).to be(true)
      expect(signature.schema.type).to eq("string")
      expect(signature.description).to include("HMAC-SHA256")
      expect(payload.ref).to eq("#/components/schemas/WebhookPayload")
      expect(payload.property(:event).enum).to eq(
        ["payout.completed", "payout.failed", "payout.processing", "payout.cancelled"]
      )
      expect(payload.property(:status).enum).to eq(
        %w[pending processing completed failed cancelled]
      )
    end
  end
end
