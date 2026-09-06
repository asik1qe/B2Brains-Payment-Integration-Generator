# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe ProviderCompiler::OpenAPI::Loader do
  def load_temp(content, extension)
    Tempfile.create(["provider_api", extension]) do |file|
      file.write(content)
      file.flush
      return described_class.new.call(file.path)
    end
  end

  it "loads YAML files into a successful Hash result" do
    result = load_temp("openapi: 3.0.3\ninfo:\n  title: API\n", ".yaml")

    expect(result).to be_success
    expect(result.value).to eq("openapi" => "3.0.3", "info" => { "title" => "API" })
    expect(result.diagnostics).to be_empty
  end

  it "loads .yml files" do
    result = load_temp("openapi: 3.0.0\n", ".yml")

    expect(result.value).to eq("openapi" => "3.0.0")
  end

  it "loads JSON files" do
    result = load_temp('{"openapi":"3.0.3"}', ".json")

    expect(result).to be_success
    expect(result.value).to eq("openapi" => "3.0.3")
  end

  it "detects JSON content for an unknown extension" do
    result = load_temp("  {\"openapi\":\"3.0.3\"}", ".txt")

    expect(result).to be_success
    expect(result.value["openapi"]).to eq("3.0.3")
  end

  it "falls back to YAML for an unknown extension" do
    result = load_temp("openapi: 3.0.3\n", ".spec")

    expect(result).to be_success
  end

  it "returns a stable failure for a missing file" do
    result = described_class.new.call("missing-provider-api.yaml")

    expect(result).to be_failure
    expect(result.errors.map(&:code)).to eq(["openapi_file_not_found"])
  end

  it "returns a parse failure for malformed YAML" do
    result = load_temp("openapi: [3.0.3\n", ".yaml")

    expect(result).to be_failure
    expect(result.errors.first.code).to eq("openapi_parse_error")
  end

  it "returns a parse failure for malformed JSON" do
    result = load_temp('{"openapi":', ".json")

    expect(result).to be_failure
    expect(result.errors.first.code).to eq("openapi_parse_error")
  end

  it "rejects scalar, array, and nil roots" do
    ["text\n", "- item\n", "null\n"].each do |content|
      result = load_temp(content, ".yaml")
      expect(result).to be_failure
      expect(result.errors.first.code).to eq("openapi_root_not_object")
    end
  end

  it "does not instantiate unsafe YAML objects" do
    result = load_temp("--- !ruby/object:Object {}\n", ".yaml")

    expect(result).to be_failure
    expect(result.errors.first.code).to eq("openapi_parse_error")
  end
end
