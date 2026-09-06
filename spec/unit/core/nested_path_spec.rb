# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::NestedPath do
  it "merges siblings at arbitrary depth and reads them with identical semantics" do
    target = {}

    described_class.put(target, "payment.amount", 100)
    described_class.put(target, "payment.reference", "abc")
    described_class.put(target, "payment.recipient.card_number", "4111")

    expect(target).to eq(
      "payment" => {
        "amount" => 100,
        "reference" => "abc",
        "recipient" => { "card_number" => "4111" }
      }
    )
    expect(described_class.fetch(target, "payment.recipient.card_number")).to eq("4111")
  end

  it "does not silently overwrite a scalar parent" do
    expect { described_class.put({ "payment" => 1 }, "payment.amount", 100) }
      .to raise_error(ArgumentError, /not an object/)
  end
end
