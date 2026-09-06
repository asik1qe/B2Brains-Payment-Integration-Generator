# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::OpenAPI::SchemaParser do
  subject(:parser) { described_class.new(document) }

  let(:document) do
    {
      "components" => {
        "schemas" => {
          "Recipient" => {
            "type" => "object",
            "required" => ["phone"],
            "properties" => { "phone" => { "type" => "string" } }
          }
        }
      }
    }
  end

  it "parses primitive string metadata" do
    schema = parser.parse({
      "type" => "string", "format" => "uuid", "nullable" => true,
      "enum" => ["a", "B"], "example" => "a"
    })

    expect(schema.type).to eq("string")
    expect(schema.format).to eq("uuid")
    expect(schema.nullable).to be(true)
    expect(schema.enum).to eq(["a", "B"])
    expect(schema.example).to eq("a")
  end

  it "maps numeric and string constraints" do
    schema = parser.parse({
      "type" => "integer", "minimum" => 10, "maximum" => 100,
      "minLength" => 2, "maxLength" => 12, "pattern" => "^[0-9]+$"
    })

    expect(schema.minimum).to eq(10)
    expect(schema.maximum).to eq(100)
    expect(schema.min_length).to eq(2)
    expect(schema.max_length).to eq(12)
    expect(schema.pattern).to eq("^[0-9]+$")
  end

  it "recursively parses object properties and required fields" do
    schema = parser.parse(
      {
        "type" => "object",
        "required" => [:recipient],
        "properties" => {
          recipient: {
            type: "object",
            properties: { phone: { type: "string", pattern: "^\\+7" } }
          }
        }
      },
      name: "Request"
    )

    expect(schema.name).to eq("Request")
    expect(schema).to be_required(:recipient)
    expect(schema.property(:recipient)).to be_object
    expect(schema.property(:recipient).property(:phone).pattern).to eq("^\\+7")
  end

  it "parses array items" do
    schema = parser.parse({ "type" => "array", "items" => { "type" => "number" } })

    expect(schema).to be_array
    expect(schema.items.type).to eq("number")
  end

  it "parses boolean and schema additionalProperties" do
    expect(parser.parse({ "additionalProperties" => false }).additional_properties).to be(false)

    schema = parser.parse({ "additionalProperties" => { "type" => "string" } })
    expect(schema.additional_properties.type).to eq("string")
  end

  it "resolves local refs while retaining component name and provenance" do
    schema = parser.parse({ "$ref" => "#/components/schemas/Recipient" })

    expect(schema.name).to eq("Recipient")
    expect(schema.ref).to eq("#/components/schemas/Recipient")
    expect(schema).to be_object
    expect(schema.property(:phone).type).to eq("string")
  end

  it "prefers an explicitly supplied name for a ref" do
    schema = parser.parse({ "$ref" => "#/components/schemas/Recipient" }, name: "Payee")

    expect(schema.name).to eq("Payee")
  end

  it "stops cyclic refs and records a review diagnostic" do
    cyclic_document = {
      "components" => {
        "schemas" => {
          "Node" => {
            "type" => "object",
            "properties" => { "child" => { "$ref" => "#/components/schemas/Node" } }
          }
        }
      }
    }
    cyclic_parser = described_class.new(cyclic_document)
    schema = cyclic_parser.parse({ "$ref" => "#/components/schemas/Node" })

    expect(schema.property(:child).unsupported_features).to include("cyclic_ref")
    diagnostic = cyclic_parser.diagnostics.find { |item| item.code == "cyclic_ref" }
    expect(diagnostic).to be_warning
    expect(diagnostic).to be_needs_review
  end

  it "records composition names without choosing a branch" do
    schema = parser.parse({
      "type" => "object", "oneOf" => [], "anyOf" => [], "allOf" => [], "not" => {}
    })

    expect(schema.unsupported_features).to eq(%w[oneOf anyOf allOf not])
    expect(schema).to be_object
  end

  it "extracts x-* extensions" do
    schema = parser.parse({
      "type" => "string", "x-provider-field" => "raw", "description" => "Text"
    })

    expect(schema.extensions).to eq("x-provider-field" => "raw")
    expect(schema.description).to eq("Text")
  end

  it "returns nil for nil or invalid schemas and diagnoses invalid values" do
    expect(parser.parse(nil)).to be_nil
    expect(parser.parse("string")).to be_nil
    expect(parser.diagnostics.map(&:code)).to include("invalid_schema")
  end
end
