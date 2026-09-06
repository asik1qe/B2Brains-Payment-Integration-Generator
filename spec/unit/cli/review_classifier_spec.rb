# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::CLI::ReviewClassifier do
  def diagnostic(code, severity: :error, state: :unresolved)
    ProviderCompiler::Core::Diagnostic.new(
      severity: severity, code: code, message: code, state: state, stage: :mapping
    )
  end

  it "separates override-resolvable diagnostics from fatal diagnostics" do
    review = diagnostic(:payout_requisite_mapping_unresolved)
    fatal = diagnostic(:operation_mapping_unresolved)

    expect(subject.reviewable([review, fatal])).to eq([review])
    expect(subject.fatal([review, fatal])).to eq([fatal])
  end

  it "does not classify informational warnings as review blockers" do
    warning = diagnostic(:money_unit_needs_review, severity: :warning, state: :needs_review)

    expect(subject.reviewable([warning])).to be_empty
    expect(subject.fatal([warning])).to be_empty
  end
end
