# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::API::SecurityScheme do
  it "requires non-empty key and type" do
    expect { described_class.new(key: "", type: "apiKey") }.to raise_error(ArgumentError)
    expect { described_class.new(key: "Auth", type: nil) }.to raise_error(ArgumentError)
  end

  it "recognizes apiKey case-insensitively and keeps key distinct from header name" do
    scheme = described_class.new(key: "ApiKeyAuth", type: "APIKEY", location: "header", name: "X-API-Key")

    expect(scheme).to be_api_key
    expect(scheme.key).to eq("ApiKeyAuth")
    expect(scheme.name).to eq("X-API-Key")
  end

  it "recognizes HTTP bearer and basic schemes case-insensitively" do
    bearer = described_class.new(key: "BearerAuth", type: "HTTP", scheme: "BEARER")
    basic = described_class.new(key: "BasicAuth", type: "http", scheme: "Basic")

    expect(bearer).to be_http
    expect(bearer).to be_bearer
    expect(basic).to be_basic
    expect(described_class.new(key: "Other", type: "oauth2", scheme: "bearer")).not_to be_bearer
  end

  it "normalizes extension keys and implements value equality" do
    attributes = { key: "Auth", type: "http", scheme: "bearer", extensions: { x: false } }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.to_h).to include(key: "Auth", type: "http", extensions: { "x" => false })
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
