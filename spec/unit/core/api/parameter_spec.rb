# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::API::Parameter do
  it "requires non-empty name and location" do
    expect { described_class.new(name: "", location: "query") }.to raise_error(ArgumentError)
    expect { described_class.new(name: "id", location: nil) }.to raise_error(ArgumentError)
  end

  it "normalizes location and exposes location helpers without rejecting unknown locations" do
    expect(described_class.new(name: "id", location: "PATH")).to be_path
    expect(described_class.new(name: "q", location: "Query")).to be_query
    expect(described_class.new(name: "token", location: "HEADER")).to be_header
    expect(described_class.new(name: "session", location: "Cookie")).to be_cookie
    expect { described_class.new(name: "custom", location: "matrix") }.not_to raise_error
  end

  it "serializes its schema recursively and implements value equality" do
    schema = ProviderCompiler::Core::API::Schema.new(type: "integer")
    attributes = { name: "page", location: "query", required: true, schema: schema, extensions: { x: 1 } }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.to_h).to include(name: "page", location: "query", required: true, schema: schema.to_h,
                                  extensions: { "x" => 1 })
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
