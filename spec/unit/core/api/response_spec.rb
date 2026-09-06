# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::API::Response do
  it "normalizes status to a string and parses numeric statuses" do
    response = described_class.new(status_code: 201)

    expect(response.status_code).to eq("201")
    expect(response.numeric_status).to eq(201)
    expect(described_class.new(status_code: "default").numeric_status).to be_nil
  end

  it "classifies success, client-error, and server-error statuses" do
    expect(described_class.new(status_code: 204)).to be_success
    expect(described_class.new(status_code: 404)).to be_client_error
    expect(described_class.new(status_code: 503)).to be_server_error
    expect(described_class.new(status_code: "default")).not_to be_success
  end

  it "looks headers up case-insensitively" do
    header = ProviderCompiler::Core::API::Parameter.new(name: "X-Rate-Limit", location: "header")
    response = described_class.new(status_code: 200, headers: { "X-Rate-Limit" => header })

    expect(response.header("x-rate-limit")).to equal(header)
  end

  it "recognizes JSON response content types" do
    expect(described_class.new(status_code: 200, content_type: "application/json")).to be_json
    expect(described_class.new(status_code: 400, content_type: "application/problem+json")).to be_json
    expect(described_class.new(status_code: 200, content_type: "text/plain")).not_to be_json
  end

  it "serializes nested headers and schemas and implements value equality" do
    schema = ProviderCompiler::Core::API::Schema.new(type: "string")
    header = ProviderCompiler::Core::API::Parameter.new(name: "Trace", location: "header")
    attributes = { status_code: 200, schema: schema, headers: { Trace: header }, examples: { ok: true } }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.to_h[:headers]["Trace"]).to eq(header.to_h)
    expect(first.to_h[:schema]).to eq(schema.to_h)
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
