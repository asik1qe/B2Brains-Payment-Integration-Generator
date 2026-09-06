# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe ProviderCompiler::CLI::ReviewPresenter do
  let(:out) { StringIO.new }
  subject(:presenter) { described_class.new(out: out) }

  it "renders a numbered review heading and problem text" do
    presenter.heading("operation.amount", index: 2, total: 4)
    presenter.problem("Factor is unknown")

    expect(out.string).to include("REVIEW 2/4 — operation.amount", "Factor is unknown")
  end

  it "renders candidates and an optional suggestion" do
    presenter.candidates(%w[first second], formatter: ->(item) { "candidate=#{item}" })

    expect(out.string).to include(
      "[1] candidate=first",
      "[2] candidate=second",
      "Suggested:",
      "[1] candidate=first"
    )
  end

  it "renders an empty candidate set without inventing a suggestion" do
    presenter.candidates([], formatter: ->(item) { item })

    expect(out.string).to include("(none detected)")
    expect(out.string).not_to include("Suggested:")
  end

  it "renders only valid choices for the current review type" do
    presenter.choose(3, manual_label: "enter manually")
    presenter.choose(0, manual_label: nil)

    expect(out.string).to include("1-3  select", "m    enter manually", "q    abort")
  end

  it "prints saved decisions with the override path" do
    presenter.saved("security -> bearerAuth", ".provider-compiler/demo.yml")

    expect(out.string).to include(
      "Saved:",
      "security -> bearerAuth",
      "Overrides:",
      ".provider-compiler/demo.yml"
    )
  end
end
