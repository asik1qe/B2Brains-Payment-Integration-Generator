# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Generation::SchemaExampleBuilder do
  subject(:builder) { described_class.new }

  it "uses explicit examples before enum and deterministic fallbacks" do
    expect(builder.build(api_schema(type: "string", example: "given", enum: ["enum"]))).to eq("given")
    expect(builder.build(api_schema(type: "string", enum: %w[first second]))).to eq("first")
    expect(builder.build(api_schema(type: "integer", minimum: 100))).to eq(100)
    expect(builder.build(api_schema(type: "number"))).to eq(0)
    expect(builder.build(api_schema(type: "boolean"))).to be(true)
    expect(builder.build(api_schema(type: "string"))).to eq("string")
  end

  it "supports UUID, date-time, and date formats" do
    expect(builder.build(api_schema(type: "string", format: "uuid"))).to eq("00000000-0000-0000-0000-000000000000")
    expect(builder.build(api_schema(type: "string", format: "date-time"))).to eq("2026-01-01T00:00:00Z")
    expect(builder.build(api_schema(type: "string", format: "date"))).to eq("2026-01-01")
  end

  it "recursively builds objects and arrays without randomness" do
    schema = api_schema(
      type: "object",
      properties: {
        "recipient" => api_schema(
          type: "object",
          properties: { "phone" => api_schema(type: "string", pattern: "^7") }
        ),
        "items" => api_schema(type: "array", items: api_schema(type: "integer", minimum: 2))
      }
    )
    expected = { "recipient" => { "phone" => "string" }, "items" => [2] }

    expect(builder.build(schema)).to eq(expected)
    expect(builder.build(schema)).to eq(expected)
  end
end
