# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Diagnostic do
  let(:required_attributes) do
    { severity: :warning, code: :ambiguous_field, message: "Review the selected field" }
  end

  it "requires non-empty severity, code, and message" do
    expect { described_class.new(**required_attributes, severity: nil) }.to raise_error(ArgumentError)
    expect { described_class.new(**required_attributes, code: "") }.to raise_error(ArgumentError)
    expect { described_class.new(**required_attributes, message: "") }.to raise_error(ArgumentError)
  end

  it "normalizes severity and rejects unknown values" do
    expect(described_class.new(**required_attributes, severity: :WARNING).severity).to eq("warning")
    expect { described_class.new(**required_attributes, severity: :fatal) }.to raise_error(ArgumentError)
  end

  it "normalizes code, stage, and state while preserving message and location" do
    location = { path: "/payments", line: 12 }
    diagnostic = described_class.new(
      **required_attributes,
      code: :ambiguous_field,
      stage: :mapping,
      state: :NEEDS_REVIEW,
      location: location
    )

    expect(diagnostic.code).to eq("ambiguous_field")
    expect(diagnostic.stage).to eq("mapping")
    expect(diagnostic.state).to eq("needs_review")
    expect(diagnostic.message).to eq("Review the selected field")
    expect(diagnostic.location).to eq(location)
  end

  it "exposes severity helpers" do
    expect(described_class.new(**required_attributes, severity: :info)).to be_info
    expect(described_class.new(**required_attributes, severity: :warning)).to be_warning
    expect(described_class.new(**required_attributes, severity: :error)).to be_error
  end

  it "keeps needs_review non-blocking" do
    diagnostic = described_class.new(**required_attributes, severity: :warning, state: :needs_review)

    expect(diagnostic).to be_needs_review
    expect(diagnostic).not_to be_unresolved
    expect(diagnostic).not_to be_blocking
  end

  it "makes errors and unresolved diagnostics blocking" do
    error = described_class.new(**required_attributes, severity: :error)
    unresolved = described_class.new(**required_attributes, severity: :warning, state: :unresolved)

    expect(error).to be_blocking
    expect(unresolved).to be_unresolved
    expect(unresolved).to be_blocking
  end

  it "isolates nested metadata from caller mutation" do
    metadata = { candidate: { score: 0.8 }, alternatives: ["amount"] }
    diagnostic = described_class.new(**required_attributes, metadata: metadata)
    metadata[:candidate][:score] = 0.1
    metadata[:alternatives] << "total"

    expect(diagnostic.metadata).to eq(candidate: { score: 0.8 }, alternatives: ["amount"])
  end

  it "has a stable representation and class-sensitive value equality" do
    first = described_class.new(**required_attributes, metadata: { reviewed: false })
    second = described_class.new(**required_attributes, metadata: { reviewed: false })

    expect(first.to_h).to eq(
      severity: "warning", code: "ambiguous_field", message: "Review the selected field",
      stage: nil, location: nil, state: nil, metadata: { reviewed: false }
    )
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
    expect(first).not_to eq(first.to_h)
  end
end
