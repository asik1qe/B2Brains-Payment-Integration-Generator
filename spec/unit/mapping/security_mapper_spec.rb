# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::SecurityMapper do
  subject(:mapper) { described_class.new }

  it "inherits global API-key security when operation security is nil" do
    provider_spec = synthetic_provider_spec
    mapping = mapper.call(provider_spec: provider_spec, operation_match: provider_spec.operations.first)

    expect(mapping).to be_api_key
    expect(mapping.scheme_key).to eq("PartnerToken")
    expect(mapping.location).to eq("header")
    expect(mapping.name).to eq("X-Partner-Token")
    expect(mapping.credential_path).to eq("api_key")
    expect(mapping).to be_auto
  end

  it "distinguishes explicitly disabled operation security" do
    provider_spec = synthetic_provider_spec
    mapping = mapper.call(provider_spec: provider_spec, operation_match: provider_spec.operations.last)

    expect(mapping).to be_nil
    expect(mapper.diagnostics).to be_empty
  end

  it "maps query API keys, bearer, and basic schemes" do
    cases = [
      [ProviderCompiler::Core::API::SecurityScheme.new(key: "Q", type: "apiKey", location: "query", name: "key"), :query?],
      [ProviderCompiler::Core::API::SecurityScheme.new(key: "B", type: "http", scheme: "bearer"), :bearer?],
      [ProviderCompiler::Core::API::SecurityScheme.new(key: "Basic", type: "http", scheme: "basic"), :basic?]
    ]
    cases.each do |scheme, predicate|
      operation = api_operation(method: :post, path: "/x", security: [{ scheme.key => [] }])
      spec = ProviderCompiler::Core::API::ProviderSpec.new(
        openapi_version: "3.0.3", operations: [operation], security_schemes: { scheme.key => scheme }
      )
      mapping = described_class.new.call(provider_spec: spec, operation_match: operation)
      expect(mapping.public_send(predicate)).to be(true)
    end
  end

  it "marks multiple alternatives for review and unsupported schemes for review" do
    first = ProviderCompiler::Core::API::SecurityScheme.new(key: "One", type: "apiKey", location: "header", name: "X-One")
    second = ProviderCompiler::Core::API::SecurityScheme.new(key: "Two", type: "apiKey", location: "header", name: "X-Two")
    operation = api_operation(method: :post, path: "/x", security: [{ "One" => [] }, { "Two" => [] }])
    spec = ProviderCompiler::Core::API::ProviderSpec.new(
      openapi_version: "3.0.3", operations: [operation], security_schemes: { "One" => first, "Two" => second }
    )

    expect(mapper.call(provider_spec: spec, operation_match: operation)).to be_needs_review
    expect(mapper.diagnostics.map(&:code)).to include("security_mapping_needs_review")
    expect(mapper.diagnostics).to all(be_blocking)
    expect(mapper.call(provider_spec: spec, operation_match: operation).metadata["alternatives"].size).to eq(2)

    oauth = ProviderCompiler::Core::API::SecurityScheme.new(key: "OAuth", type: "oauth2")
    oauth_operation = api_operation(method: :post, path: "/x", security: [{ "OAuth" => [] }])
    oauth_spec = ProviderCompiler::Core::API::ProviderSpec.new(
      openapi_version: "3.0.3", operations: [oauth_operation], security_schemes: { "OAuth" => oauth }
    )
    unsupported_mapper = described_class.new
    expect(unsupported_mapper.call(provider_spec: oauth_spec, operation_match: oauth_operation)).to be_unresolved
    expect(unsupported_mapper.diagnostics.map(&:code)).to include("security_mapping_unresolved")
  end

  it "is unresolved when an inherited requirement cannot be resolved" do
    spec = ProviderCompiler::Core::API::ProviderSpec.new(openapi_version: "3.0.3")

    expect(mapper.call(provider_spec: spec)).to be_nil
    expect(mapper.diagnostics.first.code).to eq("security_mapping_unresolved")
  end
end
