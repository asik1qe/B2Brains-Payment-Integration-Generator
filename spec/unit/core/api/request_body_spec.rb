# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::API::RequestBody do
  it "recognizes JSON and structured-suffix JSON media types" do
    expect(described_class.new(content_type: "application/json")).to be_json
    expect(described_class.new(content_type: "application/problem+json")).to be_json
    expect(described_class.new(content_type: "APPLICATION/JSON; charset=utf-8")).to be_json
  end

  it "rejects non-JSON and missing content types" do
    expect(described_class.new(content_type: "text/plain")).not_to be_json
    expect(described_class.new(content_type: nil)).not_to be_json
  end

  it "preserves schema and examples, serializes recursively, and supports value equality" do
    schema = ProviderCompiler::Core::API::Schema.new(type: "object")
    attributes = { required: true, content_type: "application/json", schema: schema,
                   examples: { sample: { "amount" => 10 } } }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.schema).to equal(schema)
    expect(first.examples).to eq("sample" => { "amount" => 10 })
    expect(first.to_h[:schema]).to eq(schema.to_h)
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
