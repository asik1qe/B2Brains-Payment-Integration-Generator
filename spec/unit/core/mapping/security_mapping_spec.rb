# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Mapping::SecurityMapping do
  it "requires a non-empty type while allowing an omitted scheme key" do
    expect { described_class.new(type: nil) }.to raise_error(ArgumentError)
    expect { described_class.new(type: "") }.to raise_error(ArgumentError)
    expect(described_class.new(type: "custom").scheme_key).to be_nil
  end

  it "recognizes security types case-insensitively" do
    expect(described_class.new(type: "APIKEY")).to be_api_key
    expect(described_class.new(type: "Bearer")).to be_bearer
    expect(described_class.new(type: "BASIC")).to be_basic
  end

  it "recognizes locations case-insensitively" do
    expect(described_class.new(type: "apiKey", location: "HEADER")).to be_header
    expect(described_class.new(type: "apiKey", location: "Query")).to be_query
    expect(described_class.new(type: "apiKey", location: "cookie")).to be_cookie
  end

  it "preserves credentials, prefix, and service parameters" do
    parameters = { audience: "payments", nested: { enabled: false } }
    mapping = described_class.new(
      scheme_key: "ApiKeyAuth",
      type: "apiKey",
      credential_path: "credentials.api_key",
      prefix: "Bearer",
      parameters: parameters
    )
    parameters[:nested][:enabled] = true

    expect(mapping.credential_path).to eq("credentials.api_key")
    expect(mapping.prefix).to eq("Bearer")
    expect(mapping.parameters).to eq("audience" => "payments", "nested" => { enabled: false })
  end

  it "exposes decision helpers and implements value equality" do
    first = described_class.new(type: "bearer", decision: :NEEDS_REVIEW)
    second = described_class.new(type: "bearer", decision: "needs_review")

    expect(first).to be_needs_review
    expect(described_class.new(type: "basic", decision: :manual)).to be_manual
    expect(described_class.new(type: "basic", decision: :unresolved)).not_to be_resolved
    expect(first.to_h).to include(type: "bearer", scheme_key: nil, parameters: {})
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
