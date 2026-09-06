# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::API::ProviderSpec do
  it "supports the minimal constructor and requires a non-empty OpenAPI version" do
    expect(described_class.new(openapi_version: "3.1.0").openapi_version).to eq("3.1.0")
    expect { described_class.new(openapi_version: nil) }.to raise_error(ArgumentError)
    expect { described_class.new(openapi_version: "") }.to raise_error(ArgumentError)
  end

  it "finds operations by case-insensitive method and exact path" do
    operation = ProviderCompiler::Core::API::Operation.new(http_method: "post", path: "/payments")
    spec = described_class.new(openapi_version: "3.0.3", operations: [operation])

    expect(spec.operation(http_method: "PoSt", path: "/payments")).to equal(operation)
    expect(spec.operation(http_method: "POST", path: "/other")).to be_nil
  end

  it "returns all operations for a path" do
    get = ProviderCompiler::Core::API::Operation.new(http_method: "GET", path: "/payments")
    post = ProviderCompiler::Core::API::Operation.new(http_method: "POST", path: "/payments")
    other = ProviderCompiler::Core::API::Operation.new(http_method: "GET", path: "/health")
    spec = described_class.new(openapi_version: "3.0.3", operations: [get, post, other])

    expect(spec.operations_for_path("/payments")).to eq([get, post])
  end

  it "normalizes schema and security-scheme keys for string or symbol lookup" do
    schema = ProviderCompiler::Core::API::Schema.new(type: "object")
    security = ProviderCompiler::Core::API::SecurityScheme.new(key: "ApiKeyAuth", type: "apiKey")
    spec = described_class.new(
      openapi_version: "3.0.3",
      schemas: { Payment: schema },
      security_schemes: { ApiKeyAuth: security }
    )

    expect(spec.schema("Payment")).to equal(schema)
    expect(spec.schema(:Payment)).to equal(schema)
    expect(spec.security_scheme("ApiKeyAuth")).to equal(security)
    expect(spec.security_scheme(:ApiKeyAuth)).to equal(security)
  end

  it "copies collections and preserves nil global security" do
    tags = ["payments"]
    spec = described_class.new(openapi_version: "3.0.3", tags: tags)
    tags << "later"

    expect(spec.tags).to eq(["payments"])
    expect(spec.global_security).to be_nil
  end

  it "serializes nested API objects recursively and preserves meaningful empty values" do
    operation = ProviderCompiler::Core::API::Operation.new(http_method: "GET", path: "/health", security: [])
    schema = ProviderCompiler::Core::API::Schema.new(type: "string")
    server = ProviderCompiler::Core::API::Server.new(url: "https://api.example.com")
    spec = described_class.new(
      openapi_version: "3.0.3",
      operations: [operation],
      schemas: { Health: schema },
      servers: [server],
      extensions: { internal: false }
    )

    expect(spec.to_h[:operations]).to eq([operation.to_h])
    expect(spec.to_h[:schemas]).to eq("Health" => schema.to_h)
    expect(spec.to_h[:servers]).to eq([server.to_h])
    expect(spec.to_h).to include(global_security: nil, tags: [], extensions: { "internal" => false })
  end

  it "implements class-sensitive value equality and a matching hash" do
    first = described_class.new(openapi_version: "3.0.3", title: "Payments")
    second = described_class.new(openapi_version: "3.0.3", title: "Payments")

    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
    expect(first).not_to eq(first.to_h)
  end
end
