# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Mapping::MatchResult do
  subject(:match) do
    described_class.new(
      candidate: "candidate",
      score: 72,
      evidence: [{ "rule" => "name", "weight" => 20 }],
      decision: :auto,
      alternatives: [{ "candidate" => "other", "score" => 40 }],
      metadata: { "margin" => 32 }
    )
  end

  it "exposes an explainable immutable-style value representation" do
    expect(match).to be_auto
    expect(match).to be_resolved
    expect(match.to_h).to include(score: 72, decision: "auto", candidate: "candidate")
    expect(match.evidence.first).to include("rule" => "name", "weight" => 20)
  end

  it "supports every decision predicate and value equality" do
    copy = described_class.new(**match.to_h)
    unresolved = described_class.new(candidate: nil, score: 0, decision: :unresolved)
    manual = described_class.new(candidate: "x", score: 1, decision: :manual)

    expect(copy).to eq(match)
    expect(unresolved).to be_unresolved
    expect(unresolved).not_to be_resolved
    expect(manual).to be_manual
  end

  it "rejects invalid scores and decisions" do
    expect { described_class.new(candidate: nil, score: "10", decision: :auto) }.to raise_error(ArgumentError)
    expect { described_class.new(candidate: nil, score: 0, decision: :guessed) }.to raise_error(ArgumentError)
  end
end
