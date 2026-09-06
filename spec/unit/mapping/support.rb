# frozen_string_literal: true


module MappingSpecSupport
  def input_provider_spec(filename)
    path = SpecPaths.fixture("synthetic", filename)
    loaded = ProviderCompiler::OpenAPI::Loader.new.call(path)
    ProviderCompiler::OpenAPI::Parser.new.call(loaded.value).value
  end

  def novapay_provider_spec
    path = SpecPaths.fixture("official", "novapay_provider_api.yaml")
    loaded = ProviderCompiler::OpenAPI::Loader.new.call(path)
    ProviderCompiler::OpenAPI::Parser.new.call(loaded.value).value
  end

  def api_schema(type: nil, **attributes)
    ProviderCompiler::Core::API::Schema.new(type: type, **attributes)
  end

  def api_response(status, schema: nil, description: nil, headers: {})
    ProviderCompiler::Core::API::Response.new(
      status_code: status,
      description: description,
      content_type: schema ? "application/json" : nil,
      schema: schema,
      headers: headers
    )
  end

  def api_operation(method:, path:, operation_id: nil, summary: nil, description: nil,
                    tags: [], parameters: [], request_schema: nil, responses: {}, security: nil)
    ProviderCompiler::Core::API::Operation.new(
      http_method: method,
      path: path,
      operation_id: operation_id,
      summary: summary,
      description: description,
      tags: tags,
      parameters: parameters,
      request_body: request_schema && ProviderCompiler::Core::API::RequestBody.new(
        required: true,
        content_type: "application/json",
        schema: request_schema
      ),
      responses: responses,
      security: security
    )
  end

  def synthetic_provider_spec
    beneficiary = api_schema(
      type: "object",
      required: ["card_number"],
      properties: { "card_number" => api_schema(type: "string") }
    )
    create_request = api_schema(
      type: "object",
      required: %w[sum reference_id beneficiary],
      properties: {
        "sum" => api_schema(type: "integer", description: "Amount in cents", minimum: 100),
        "reference_id" => api_schema(type: "string", description: "Client reference"),
        "beneficiary" => beneficiary
      }
    )
    transaction = api_schema(
      type: "object",
      properties: {
        "transaction_id" => api_schema(type: "string"),
        "state" => api_schema(type: "string", enum: %w[queued succeeded declined])
      }
    )
    callback = api_schema(
      type: "object",
      properties: {
        "event" => api_schema(type: "string", enum: ["transaction.succeeded"]),
        "state" => api_schema(type: "string", enum: %w[queued succeeded declined]),
        "transaction_id" => api_schema(type: "string"),
        "reference_id" => api_schema(type: "string"),
        "failure" => api_schema(type: "object")
      }
    )
    transaction_parameter = ProviderCompiler::Core::API::Parameter.new(
      name: "transaction_id",
      location: "path",
      required: true,
      schema: api_schema(type: "string")
    )
    signature = ProviderCompiler::Core::API::Parameter.new(
      name: "Digest-Signature",
      location: "header",
      required: true,
      schema: api_schema(type: "string"),
      description: "HMAC-SHA512 signature"
    )
    retry_after = ProviderCompiler::Core::API::Parameter.new(
      name: "Retry-After",
      location: "header",
      schema: api_schema(type: "integer")
    )

    create = api_operation(
      method: :post,
      path: "/transfers",
      operation_id: "initiateTransfer",
      summary: "Initiate transfer",
      request_schema: create_request,
      responses: {
        "201" => api_response(201, schema: transaction),
        "401" => api_response(401, description: "Unauthorized"),
        "429" => api_response(429, description: "Rate limited", headers: { "Retry-After" => retry_after })
      }
    )
    fetch = api_operation(
      method: :get,
      path: "/transactions/{transaction_id}",
      operation_id: "retrieveTransaction",
      summary: "Retrieve transaction state",
      parameters: [transaction_parameter],
      responses: { "200" => api_response(200, schema: transaction) }
    )
    notification = api_operation(
      method: :post,
      path: "/notifications",
      operation_id: "transactionNotification",
      summary: "Transaction event notification",
      parameters: [signature],
      request_schema: callback,
      responses: { "200" => api_response(200) },
      security: []
    )
    security = ProviderCompiler::Core::API::SecurityScheme.new(
      key: "PartnerToken",
      type: "apiKey",
      location: "header",
      name: "X-Partner-Token"
    )

    ProviderCompiler::Core::API::ProviderSpec.new(
      openapi_version: "3.0.3",
      title: "Orbit Transfer API",
      operations: [create, fetch, notification],
      security_schemes: { "PartnerToken" => security },
      global_security: [{ "PartnerToken" => [] }]
    )
  end

  def unknown_requisite_provider_spec
    original = synthetic_provider_spec
    recipient = api_schema(
      type: "object",
      required: %w[iban tax_id],
      properties: {
        "iban" => api_schema(type: "string"),
        "tax_id" => api_schema(type: "string"),
        "account_name" => api_schema(type: "string")
      }
    )
    request = api_schema(
      type: "object",
      required: %w[sum reference_id recipient],
      properties: {
        "sum" => api_schema(type: "integer", description: "Amount in cents"),
        "reference_id" => api_schema(type: "string"),
        "recipient" => recipient
      }
    )
    create = api_operation(
      method: :post,
      path: "/transfers",
      operation_id: "createTransfer",
      summary: "Create transfer",
      request_schema: request,
      responses: original.operations.first.responses
    )
    ProviderCompiler::Core::API::ProviderSpec.new(
      openapi_version: "3.0.3",
      title: "Unknown Requisite API",
      operations: [create, original.operations[1], original.operations[2]],
      security_schemes: original.security_schemes,
      global_security: original.global_security
    )
  end
end

RSpec.configure do |config|
  config.include MappingSpecSupport
end
