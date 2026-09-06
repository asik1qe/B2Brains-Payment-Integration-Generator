# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::OpenAPI::SupportPolicy do
  def codes_for(document)
    described_class.new.call(document).map(&:code)
  end

  it "accepts OpenAPI 3.0.0 and 3.0.3" do
    expect(codes_for("openapi" => "3.0.0")).to be_empty
    expect(codes_for("openapi" => "3.0.3")).to be_empty
  end

  it "rejects OpenAPI 3.1 and Swagger 2.0" do
    expect(codes_for("openapi" => "3.1.0")).to include("unsupported_openapi_version")
    expect(codes_for("swagger" => "2.0")).to include("missing_openapi_version")
  end

  it "reports a missing version" do
    diagnostic = described_class.new.call({}).first

    expect(diagnostic.code).to eq("missing_openapi_version")
    expect(diagnostic).to be_error
  end

  it "accepts local refs and rejects external refs as unresolved" do
    local = { "openapi" => "3.0.3", "schema" => { "$ref" => "#/components/schemas/A" } }
    external = { "openapi" => "3.0.3", "schema" => { "$ref" => "other.yaml#/A" } }

    expect(codes_for(local)).not_to include("external_ref_unsupported")
    diagnostic = described_class.new.call(external).find { |item| item.code == "external_ref_unsupported" }
    expect(diagnostic).to be_error
    expect(diagnostic).to be_unresolved
    expect(diagnostic.location).to eq("#/schema/$ref")
  end

  it "warns for every unsupported composition feature" do
    document = {
      "openapi" => "3.0.3",
      "schema" => { "oneOf" => [], "anyOf" => [], "allOf" => [], "not" => {} }
    }
    diagnostics = described_class.new.call(document).select do |item|
      item.code == "schema_composition_unsupported"
    end

    expect(diagnostics.length).to eq(4)
    expect(diagnostics).to all(be_warning.and be_needs_review)
  end

  it "accepts JSON content even when a non-JSON alternative exists" do
    document = {
      "openapi" => "3.0.3",
      "paths" => {
        "/items" => {
          "post" => {
            "requestBody" => {
              "content" => { "application/xml" => {}, "application/json" => {} }
            }
          }
        }
      }
    }

    expect(codes_for(document)).not_to include("non_json_content_unsupported")
  end

  it "warns when request or response content has only non-JSON media types" do
    document = {
      "openapi" => "3.0.3",
      "paths" => {
        "/items" => {
          "post" => {
            "requestBody" => { "content" => { "multipart/form-data" => {} } },
            "responses" => { "200" => { "content" => { "application/xml" => {} } } }
          }
        }
      }
    }

    diagnostics = described_class.new.call(document).select do |item|
      item.code == "non_json_content_unsupported"
    end
    expect(diagnostics.length).to eq(2)
    expect(diagnostics).to all(be_warning.and be_needs_review)
  end

  it "accepts apiKey and HTTP security but warns for unsupported types" do
    base = {
      "openapi" => "3.0.3",
      "components" => {
        "securitySchemes" => {
          "Key" => { "type" => "apiKey" },
          "Bearer" => { "type" => "http" },
          "OAuth" => { "type" => "oauth2" },
          "OIDC" => { "type" => "openIdConnect" }
        }
      }
    }

    diagnostics = described_class.new.call(base).select do |item|
      item.code == "security_scheme_unsupported"
    end
    expect(diagnostics.length).to eq(2)
    expect(diagnostics.map(&:location)).to include(
      "#/components/securitySchemes/OAuth", "#/components/securitySchemes/OIDC"
    )
  end

  it "warns for path-level and operation-level servers" do
    document = {
      "openapi" => "3.0.3",
      "paths" => {
        "/items" => {
          "servers" => [{ "url" => "https://path.test" }],
          "get" => { "servers" => [{ "url" => "https://operation.test" }] }
        }
      }
    }

    expect(codes_for(document).count("operation_servers_unsupported")).to eq(2)
  end
end
