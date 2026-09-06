# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::API::Operation do
  it "requires a non-empty method and path and uppercases the method" do
    expect(described_class.new(http_method: :post, path: "/payments").http_method).to eq("POST")
    expect { described_class.new(http_method: "", path: "/payments") }.to raise_error(ArgumentError)
    expect { described_class.new(http_method: "GET", path: "") }.to raise_error(ArgumentError)
  end

  it "normalizes response keys and looks responses up by integer or string" do
    response = ProviderCompiler::Core::API::Response.new(status_code: 201)
    operation = described_class.new(http_method: "POST", path: "/payments", responses: { 201 => response })

    expect(operation.response(201)).to equal(response)
    expect(operation.response("201")).to equal(response)
  end

  it "looks parameters up by name and optional case-insensitive location" do
    query = ProviderCompiler::Core::API::Parameter.new(name: "id", location: "query")
    header = ProviderCompiler::Core::API::Parameter.new(name: "id", location: "header")
    operation = described_class.new(http_method: "GET", path: "/payments", parameters: [query, header])

    expect(operation.parameter(:id)).to equal(query)
    expect(operation.parameter("id", location: "HEADER")).to equal(header)
  end

  it "returns only exact numeric 2xx responses" do
    ok = ProviderCompiler::Core::API::Response.new(status_code: 200)
    created = ProviderCompiler::Core::API::Response.new(status_code: 201)
    operation = described_class.new(
      http_method: "POST",
      path: "/payments",
      responses: { "200" => ok, 201 => created, "2XX" => ok, "default" => ok, "400" => ok }
    )

    expect(operation.success_responses).to eq("200" => ok, "201" => created)
  end

  it "distinguishes inherited security from explicitly disabled security" do
    inherited = described_class.new(http_method: "GET", path: "/payments")
    disabled = described_class.new(http_method: "GET", path: "/health", security: [])

    expect(inherited).to be_inherits_global_security
    expect(inherited).not_to be_security_disabled
    expect(disabled).not_to be_inherits_global_security
    expect(disabled).to be_security_disabled
  end

  it "copies collections and normalizes security requirement keys" do
    tags = ["payments"]
    security = [{ ApiKeyAuth: [] }]
    operation = described_class.new(http_method: "GET", path: "/payments", tags: tags, security: security)
    tags << "later"
    security.first[:Other] = []

    expect(operation.tags).to eq(["payments"])
    expect(operation.security).to eq([{ "ApiKeyAuth" => [] }])
  end

  it "serializes nested API objects and implements value equality" do
    body = ProviderCompiler::Core::API::RequestBody.new(required: true)
    response = ProviderCompiler::Core::API::Response.new(status_code: 201)
    attributes = { http_method: "post", path: "/payments", request_body: body, responses: { 201 => response } }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.to_h[:request_body]).to eq(body.to_h)
    expect(first.to_h[:responses]["201"]).to eq(response.to_h)
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
