# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::API::Schema do
  describe "type helpers" do
    it "distinguishes object, array, and primitive schemas" do
      expect(described_class.new(type: "OBJECT")).to be_object
      expect(described_class.new(type: "array")).to be_array
      expect(described_class.new(type: "string")).to be_primitive
      expect(described_class.new).not_to be_primitive
    end
  end

  it "normalizes property and required names and supports lookup" do
    child = described_class.new(type: "string")
    schema = described_class.new(properties: { amount: child }, required: [:amount])

    expect(schema.properties).to eq("amount" => child)
    expect(schema.property(:amount)).to equal(child)
    expect(schema).to be_required("amount")
  end

  it "reports whether enum was specified without changing its values" do
    values = ["new", 1, false, nil]
    schema = described_class.new(enum: values)
    values << "later"

    expect(schema).to be_enum
    expect(schema.enum).to eq(["new", 1, false, nil])
    expect(described_class.new).not_to be_enum
  end

  it "returns only specified constraints" do
    schema = described_class.new(minimum: 0, max_length: 64, pattern: "^[a-z]+$")

    expect(schema.constraints).to eq(minimum: 0, max_length: 64, pattern: "^[a-z]+$")
  end

  it "preserves nested properties, array items, refs, and unsupported features" do
    item = described_class.new(ref: "#/components/schemas/Payment")
    array = described_class.new(type: "array", items: item, unsupported_features: ["oneOf"])
    object = described_class.new(type: "object", properties: { payments: array })

    expect(object.property("payments").items).to equal(item)
    expect(item.ref).to eq("#/components/schemas/Payment")
    expect(array.unsupported_features).to eq(["oneOf"])
  end

  it "supports boolean and schema additional_properties" do
    value_schema = described_class.new(type: "integer")

    expect(described_class.new(additional_properties: false).additional_properties).to be(false)
    expect(described_class.new(additional_properties: value_schema).additional_properties).to equal(value_schema)
  end

  it "serializes nested schemas recursively and keeps nil and empty fields" do
    child = described_class.new(type: "string")
    schema = described_class.new(type: "object", properties: { child: child })

    expect(schema.to_h[:properties]["child"]).to eq(child.to_h)
    expect(schema.to_h).to include(enum: nil, required: [], nullable: false, extensions: {})
  end

  it "implements class-sensitive value equality and a matching hash" do
    first = described_class.new(type: "string", max_length: 10)
    second = described_class.new(type: "string", max_length: 10)

    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
    expect(first).not_to eq(first.to_h)
  end
end
