# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Mapping::StatusMapping do
  it "normalizes provider-status keys but preserves mapped values" do
    mapping = described_class.new(mappings: { pending: "in_progress", "COMPLETED" => :approved })

    expect(mapping.map(:pending)).to eq("in_progress")
    expect(mapping.map("COMPLETED")).to eq(:approved)
    expect(mapping.provider_statuses).to eq(%w[pending COMPLETED])
  end

  it "returns nil or the configured fallback for an unknown status" do
    expect(described_class.new.map("missing")).to be_nil
    expect(described_class.new(unknown_status: "unknown").map("missing")).to eq("unknown")
  end

  it "distinguishes a mapped nil value from a missing key" do
    mapping = described_class.new(mappings: { waiting: nil })

    expect(mapping).to be_mapped(:waiting)
    expect(mapping).not_to be_mapped(:missing)
  end

  it "returns unique internal statuses in insertion order" do
    mapping = described_class.new(
      mappings: { pending: "in_progress", processing: "in_progress", completed: "approved" }
    )

    expect(mapping.internal_statuses).to eq(%w[in_progress approved])
  end

  it "exposes decision helpers" do
    expect(described_class.new(decision: :AUTO)).to be_auto
    expect(described_class.new(decision: :needs_review)).to be_needs_review
    expect(described_class.new(decision: :manual)).to be_manual
    expect(described_class.new(decision: :unresolved)).to be_unresolved
    expect(described_class.new(decision: :manual)).to be_resolved
  end

  it "serializes all fields and implements value equality" do
    attributes = { mappings: { completed: "approved" }, evidence: ["explicit enum"], metadata: { x: false } }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.to_h).to include(
      mappings: { "completed" => "approved" }, decision: "auto",
      evidence: ["explicit enum"], unknown_status: nil, metadata: { x: false }
    )
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
