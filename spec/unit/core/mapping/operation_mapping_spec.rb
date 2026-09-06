# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Mapping::OperationMapping do
  let(:operation) do
    ProviderCompiler::Core::API::Operation.new(http_method: "POST", path: "/payments")
  end

  it "requires a non-empty role and operation" do
    expect { described_class.new(role: "", operation: operation) }.to raise_error(ArgumentError)
    expect { described_class.new(role: :create_request, operation: nil) }.to raise_error(ArgumentError)
  end

  it "normalizes role and decision while preserving score and evidence" do
    mapping = described_class.new(
      role: :create_request,
      operation: operation,
      decision: :NEEDS_REVIEW,
      score: 0.82,
      evidence: [{ reason: "operation id" }]
    )

    expect(mapping.role).to eq("create_request")
    expect(mapping.decision).to eq("needs_review")
    expect(mapping.score).to eq(0.82)
    expect(mapping.evidence).to eq([{ reason: "operation id" }])
    expect(mapping).to be_needs_review
  end

  it "exposes all decision helpers and considers only unresolved decisions unresolved" do
    expect(described_class.new(role: "a", operation: operation)).to be_auto
    expect(described_class.new(role: "a", operation: operation, decision: :manual)).to be_manual

    unresolved = described_class.new(role: "a", operation: operation, decision: :unresolved)
    expect(unresolved).to be_unresolved
    expect(unresolved).not_to be_resolved
  end

  it "serializes the nested API operation and implements value equality" do
    first = described_class.new(role: :create_request, operation: operation)
    second = described_class.new(role: "create_request", operation: operation)

    expect(first.to_h[:operation]).to eq(operation.to_h)
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
