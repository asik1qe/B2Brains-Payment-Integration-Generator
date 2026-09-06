# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Mapping::Transformations::NestedObject do
  let(:value) { { "recipient" => { "phone" => "70000000000" }, "items" => [1] } }

  it "gets dotted paths and returns nil for missing paths" do
    expect(described_class.get(value, "recipient.phone")).to eq("70000000000")
    expect(described_class.get(value, "recipient.bank")).to be_nil
  end

  it "sets dotted paths without mutating the input" do
    updated = described_class.set(value, "recipient.bank.code", "123")
    symbol_input = { recipient: { phone: "70000000000" } }
    symbol_updated = described_class.set(symbol_input, "recipient.phone", "71111111111")

    expect(updated.dig("recipient", "bank", "code")).to eq("123")
    expect(value).to eq("recipient" => { "phone" => "70000000000" }, "items" => [1])
    expect(symbol_updated).to eq(recipient: { phone: "71111111111" })
    expect(symbol_input).to eq(recipient: { phone: "70000000000" })
  end

  it "describes nested-object transformations" do
    expect(described_class.descriptor(provider_path: "recipient")).to eq(
      "type" => "nested_object", "provider_path" => "recipient"
    )
  end
end
