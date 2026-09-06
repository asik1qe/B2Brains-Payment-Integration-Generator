# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::OpenAPI::Normalizer do
  it "recursively stringifies Hash keys through arrays" do
    input = { info: { title: "API" }, servers: [{ url: "https://example.test" }] }

    expect(described_class.new.call(input)).to eq(
      "info" => { "title" => "API" },
      "servers" => [{ "url" => "https://example.test" }]
    )
  end

  it "returns new Hash and Array instances without mutating the input" do
    input = { schemas: [{ properties: { amount: { type: "integer" } } }] }
    normalized = described_class.new.call(input)
    normalized["schemas"].first["properties"]["amount"]["type"] = "number"

    expect(input).to eq(schemas: [{ properties: { amount: { type: "integer" } } }])
  end

  it "does not change scalar values" do
    description = "Сумма в копейках — НЕ менять"
    pattern = "^\\+7\\d{10}$"
    values = ["Pending", :approved, 10, false, nil]
    normalized = described_class.new.call(
      description: description, pattern: pattern, enum: values, operationId: "CreatePayout"
    )

    expect(normalized["description"]).to equal(description)
    expect(normalized["pattern"]).to equal(pattern)
    expect(normalized["enum"]).to eq(values)
    expect(normalized["operationId"]).to eq("CreatePayout")
  end

  it "preserves examples, paths, and URLs exactly" do
    input = {
      paths: { "/Payouts/{id}" => { example: { Status: "MixedCase" } } },
      url: "HTTPS://API.Example.test/V1"
    }

    normalized = described_class.new.call(input)
    expect(normalized["paths"].keys).to eq(["/Payouts/{id}"])
    expect(normalized["paths"]["/Payouts/{id}"]["example"]["Status"]).to eq("MixedCase")
    expect(normalized["url"]).to eq("HTTPS://API.Example.test/V1")
  end
end
