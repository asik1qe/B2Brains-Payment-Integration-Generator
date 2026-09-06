# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Mapping::Transformations::Registry do
  it "registers exactly the supported descriptor types" do
    expect(described_class.types).to contain_exactly("money", "date_time", "enum", "nested_object", "type_cast")
    expect(described_class).to be_registered("money")
    expect(described_class.fetch(:money)).to eq(ProviderCompiler::Mapping::Transformations::Money)
    expect(described_class.fetch("unknown")).to be_nil
  end
end
