# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Mapping::Transformations::Enum do
  let(:mapping) { { pending: "in_progress", completed: "approved" } }

  it "creates descriptors and maps in both directions" do
    expect(described_class.descriptor(mapping: mapping)).to eq(
      "type" => "enum", "mapping" => { "pending" => "in_progress", "completed" => "approved" }
    )
    expect(described_class.map(:pending, mapping: mapping)).to eq("in_progress")
    expect(described_class.reverse_map("approved", mapping: mapping)).to eq("completed")
    expect(described_class.map(:unknown, mapping: mapping)).to be_nil
  end
end
