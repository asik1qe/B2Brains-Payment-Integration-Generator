# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "yaml"

RSpec.describe "extended OpenAPI policy acceptance" do
  def write_variant(root, source_name)
    document = YAML.safe_load_file(SpecPaths.fixture("synthetic", source_name), aliases: false)
    yield document
    path = File.join(root, "variant.yaml")
    File.write(path, YAML.dump(document), mode: "w", encoding: "UTF-8")
    path
  end

  def run_variant(path, root, provider: "policy_variant")
    output = File.join(root, "output")
    code, stdout, stderr = run_cli([
      "--spec", path,
      "--provider", provider,
      "--output", output,
      "--non-interactive",
      "--force"
    ])
    [code, stdout, stderr, output]
  end

  %w[oneOf anyOf allOf not].each do |keyword|
    it "blocks #{keyword} when it changes the selected create-request schema" do
      with_tmpdir do |root|
        path = write_variant(root, "08_riverpay_bearer_query_nested.yaml") do |document|
          schema = document.dig("components", "schemas", "TransferRequest")
          schema[keyword] = keyword == "not" ? { "type" => "null" } : [{ "type" => "object" }]
        end
        code, _stdout, stderr, output = run_variant(path, root, provider: "critical_#{keyword.downcase}")

        expect(code).to eq(1)
        expect(stderr).to include("critical_schema_composition_unsupported")
        expect(Dir.exist?(output)).to be(false)
      end
    end
  end

  it "accepts a JSON request body even when an unsupported media type is also advertised" do
    with_tmpdir do |root|
      path = write_variant(root, "08_riverpay_bearer_query_nested.yaml") do |document|
        content = document.dig("paths", "/transfers", "post", "requestBody", "content")
        content["application/xml"] = { "schema" => { "type" => "string" } }
      end
      code, stdout, stderr, output = run_variant(path, root, provider: "json_preferred")

      expect(code).to eq(0), stderr
      expect(stdout).to include("Status: SUCCESS")
      expect(Dir.children(output)).to contain_exactly("json_preferred_service.rb", "INTEGRATION.md", "fixtures.json")
    end
  end

  it "blocks an unsupported AND authentication requirement instead of dropping one scheme" do
    with_tmpdir do |root|
      path = write_variant(root, "16_ambiguous_security.yaml") do |document|
        document.dig("paths", "/transfers", "post")["security"] = [{ "BearerAuth" => [], "AltApiKey" => [] }]
        document.dig("paths", "/operations", "get")["security"] = [{ "BearerAuth" => [], "AltApiKey" => [] }]
      end
      code, _stdout, stderr, output = run_variant(path, root, provider: "security_and")

      expect(code).to eq(1)
      expect(stderr).to include("security_mapping_unresolved")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "blocks different effective authentication between create and fetch operations" do
    with_tmpdir do |root|
      path = write_variant(root, "08_riverpay_bearer_query_nested.yaml") do |document|
        document.fetch("components").fetch("securitySchemes")["StatusApiKey"] = {
          "type" => "apiKey", "in" => "query", "name" => "status_key"
        }
        document.dig("paths", "/operations", "get")["security"] = [{ "StatusApiKey" => [] }]
      end
      code, _stdout, stderr, output = run_variant(path, root, provider: "mixed_security")

      expect(code).to eq(1)
      expect(stderr).to include("security_mapping_unresolved")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "rejects unsupported OpenAPI versions before mapping or generation" do
    with_tmpdir do |root|
      path = write_variant(root, "08_riverpay_bearer_query_nested.yaml") do |document|
        document["openapi"] = "3.1.0"
      end
      code, _stdout, stderr, output = run_variant(path, root, provider: "oas_31")

      expect(code).to eq(1)
      expect(stderr).to include("unsupported_openapi_version")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "blocks a required fetch parameter with neither a platform mapping nor a safe constant" do
    with_tmpdir do |root|
      path = write_variant(root, "08_riverpay_bearer_query_nested.yaml") do |document|
        operation = document.dig("paths", "/operations", "get")
        operation["parameters"] ||= []
        operation["parameters"] << {
          "name" => "region", "in" => "query", "required" => true,
          "schema" => { "type" => "string" }
        }
      end
      code, _stdout, stderr, output = run_variant(path, root, provider: "required_fetch_unknown")

      expect(code).to eq(1)
      expect(stderr).to include("required_request_parameter_unresolved")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "materializes a required single-enum fetch parameter as a deterministic query constant" do
    with_tmpdir do |root|
      path = write_variant(root, "08_riverpay_bearer_query_nested.yaml") do |document|
        operation = document.dig("paths", "/operations", "get")
        operation["parameters"] ||= []
        operation["parameters"] << {
          "name" => "currency", "in" => "query", "required" => true,
          "schema" => { "type" => "string", "enum" => ["RUB"] }
        }
      end
      code, stdout, stderr, output = run_variant(path, root, provider: "required_fetch_constant")

      expect(code).to eq(0), stderr
      expect(stdout).to include("Status: SUCCESS")
      source = File.read(File.join(output, "required_fetch_constant_service.rb"), encoding: "UTF-8")
      expect(source).to include('query["currency"] = "RUB"')
    end
  end

  it "blocks a path-level server override for a selected operation rather than silently using the root server" do
    with_tmpdir do |root|
      path = write_variant(root, "08_riverpay_bearer_query_nested.yaml") do |document|
        document.dig("paths", "/transfers")["servers"] = [{ "url" => "https://special.example.test" }]
      end
      code, _stdout, stderr, output = run_variant(path, root, provider: "path_server_override")

      expect(code).to eq(1)
      expect(stderr).to include("critical_operation_servers_unsupported")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "materializes required single-value enums as deterministic provider constants" do
    with_tmpdir do |root|
      output = File.join(root, "output")
      code, stdout, stderr = run_cli([
        "--spec", SpecPaths.fixture("official", "novapay_provider_api.yaml"),
        "--provider", "enum_constant",
        "--output", output,
        "--non-interactive",
        "--force"
      ])

      expect(code).to eq(0), stderr
      expect(stdout).to include("Status: SUCCESS")
      fixture = JSON.parse(File.read(File.join(output, "fixtures.json"), encoding: "UTF-8"))
      expect(fixture.dig("create_request", "provider_request", "currency")).to eq("RUB")
    end
  end
end
