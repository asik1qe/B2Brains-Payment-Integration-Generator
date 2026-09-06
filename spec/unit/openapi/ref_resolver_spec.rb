# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::OpenAPI::RefResolver do
  let(:document) do
    {
      "components" => {
        "schemas" => { "Payment" => { "type" => "object" }, "a/b" => 1, "a~b" => 2 },
        "parameters" => { "IdempotencyKey" => { "name" => "Idempotency-Key" } }
      },
      "nested" => { "array" => [{ "value" => 3 }] }
    }
  end

  subject(:resolver) { described_class.new(document) }

  it "recognizes only local JSON Pointer refs" do
    expect(resolver).to be_local_ref("#/components/schemas/Payment")
    expect(resolver).not_to be_local_ref("other.yaml#/Payment")
    expect(resolver).not_to be_local_ref(nil)
  end

  it "resolves local schema and parameter refs" do
    expect(resolver.resolve("#/components/schemas/Payment")).to eq("type" => "object")
    expect(resolver.resolve("#/components/parameters/IdempotencyKey")).to eq(
      "name" => "Idempotency-Key"
    )
  end

  it "resolves nested Hash and Array paths" do
    expect(resolver.resolve("#/nested/array/0/value")).to eq(3)
  end

  it "decodes JSON Pointer slash escapes" do
    expect(resolver.resolve("#/components/schemas/a~1b")).to eq(1)
  end

  it "decodes JSON Pointer tilde escapes" do
    expect(resolver.resolve("#/components/schemas/a~0b")).to eq(2)
  end

  it "records an unresolved missing-ref diagnostic" do
    expect(resolver.resolve("#/components/schemas/Missing")).to be_nil
    diagnostic = resolver.diagnostics.last

    expect(diagnostic.code).to eq("ref_not_found")
    expect(diagnostic).to be_error
    expect(diagnostic).to be_unresolved
  end

  it "records external and invalid refs without raising" do
    expect(resolver.resolve("other.yaml#/Payment")).to be_nil
    expect(resolver.resolve("#/bad~2escape")).to be_nil
    expect(resolver.resolve(nil)).to be_nil

    expect(resolver.diagnostics.map(&:code)).to eq(
      %w[external_ref_unsupported invalid_ref invalid_ref]
    )
  end

  it "does not mutate the document" do
    original = Marshal.load(Marshal.dump(document))
    resolver.resolve("#/components/schemas/Payment")

    expect(document).to eq(original)
  end
end
