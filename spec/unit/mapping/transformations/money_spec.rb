# frozen_string_literal: true

require "spec_helper"
require_relative "../support"

RSpec.describe ProviderCompiler::Mapping::Transformations::Money do
  it "infers common minor units from English and Russian schema descriptions" do
    expect(described_class.infer_unit(api_schema(description: "Amount in kopecks"))).to eq("kopecks")
    expect(described_class.infer_unit(api_schema(description: "Сумма в копейках"))).to eq("kopecks")
    expect(described_class.infer_unit(api_schema(description: "Value in cents"))).to eq("cents")
    expect(described_class.infer_unit(api_schema(description: "Amount in minor units"))).to eq("minor_units")
    expect(described_class.infer_unit(api_schema(description: "Amount"))).to be_nil
  end

  it "returns integer factors and stable string-keyed descriptors" do
    expect(described_class.factor_for("kopecks")).to eq(100)
    expect(described_class.factor_for("cents")).to eq(100)
    expect(described_class.factor_for("minor_units")).to be_nil
    expect(described_class.descriptor(unit: :kopecks)).to eq(
      "type" => "money", "unit" => "kopecks", "factor" => 100
    )
  end
end
