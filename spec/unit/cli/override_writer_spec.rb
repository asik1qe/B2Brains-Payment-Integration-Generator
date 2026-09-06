# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"

RSpec.describe ProviderCompiler::CLI::OverrideWriter do
  it "merges one decision while preserving unrelated user keys" do
    Dir.mktmpdir do |root|
      path = File.join(root, "mapping.yml")
      File.write(path, YAML.dump("custom" => { "keep" => false }, "fields" => {
        "operation.amount" => { "provider_path" => "value", "direction" => "request" }
      }))
      writer = described_class.new(path)

      writer.field(
        "operation.amount", provider_path: "value", direction: "request",
        transformation: { "type" => "money", "unit" => "minor_units", "factor" => 100 }
      )

      data = YAML.safe_load_file(path)
      expect(data.dig("custom", "keep")).to be(false)
      expect(data.dig("fields", "operation.amount", "transformation", "factor")).to eq(100)
      expect(File.read(path)).to eq(YAML.dump(data.sort.to_h))
    end
  end

  it "preserves multiple provider bindings for the same internal field" do
    Dir.mktmpdir do |root|
      path = File.join(root, "mapping.yml")
      writer = described_class.new(path)

      writer.field(
        "operation.payout_requisite.card_number",
        provider_path: "beneficiary.iban", direction: "request", required: true
      )
      writer.field(
        "operation.payout_requisite.card_number",
        provider_path: "beneficiary.tax_id", direction: "request", required: true
      )

      bindings = YAML.safe_load_file(path).dig("fields", "operation.payout_requisite.card_number")
      expect(bindings).to contain_exactly(
        include("provider_path" => "beneficiary.iban", "direction" => "request"),
        include("provider_path" => "beneficiary.tax_id", "direction" => "request")
      )
    end
  end

  it "creates parent directories on the first manual decision" do
    Dir.mktmpdir do |root|
      path = File.join(root, ".provider-compiler", "orbit.overrides.yml")
      operation = ProviderCompiler::Core::API::Operation.new(http_method: :post, path: "/payouts")

      described_class.new(path).operation("create_request", operation)

      expect(YAML.safe_load_file(path)).to include("operations")
    end
  end
end
