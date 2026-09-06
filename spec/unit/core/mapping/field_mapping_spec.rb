# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Mapping::FieldMapping do
  let(:required_attributes) do
    { internal_path: "operation.amount", provider_path: "payload.amount", direction: :REQUEST }
  end

  it "requires non-empty internal path, provider path, and direction" do
    expect { described_class.new(**required_attributes, internal_path: "") }.to raise_error(ArgumentError)
    expect { described_class.new(**required_attributes, provider_path: nil) }.to raise_error(ArgumentError)
    expect { described_class.new(**required_attributes, direction: "") }.to raise_error(ArgumentError)
  end

  it "normalizes direction and exposes direction helpers" do
    expect(described_class.new(**required_attributes)).to be_request
    expect(described_class.new(**required_attributes, direction: "Response")).to be_response
    expect(described_class.new(**required_attributes, direction: :WEBHOOK)).to be_webhook
  end

  it "reports transformations without interpreting their configuration" do
    transformation = { "type" => "money", "unit" => "kopecks", options: { round: false } }
    mapping = described_class.new(**required_attributes, transformation: transformation)
    transformation[:options][:round] = true

    expect(mapping).to be_transformed
    expect(mapping.transformation).to eq(
      "type" => "money", "unit" => "kopecks", options: { round: false }
    )
    expect(described_class.new(**required_attributes)).not_to be_transformed
  end

  it "exposes decision helpers" do
    expect(described_class.new(**required_attributes, decision: :AUTO)).to be_auto
    expect(described_class.new(**required_attributes, decision: :needs_review)).to be_needs_review
    expect(described_class.new(**required_attributes, decision: :manual)).to be_manual

    unresolved = described_class.new(**required_attributes, decision: :unresolved)
    expect(unresolved).to be_unresolved
    expect(unresolved).not_to be_resolved
  end

  it "keeps a stable hash representation and implements value equality" do
    first = described_class.new(**required_attributes, required: false)
    second = described_class.new(**required_attributes, required: false)

    expect(first.to_h).to include(
      internal_path: "operation.amount", provider_path: "payload.amount",
      direction: "request", transformation: nil, required: false
    )
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
