# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Result do
  def diagnostic(severity: :info, state: nil, code: :notice)
    ProviderCompiler::Core::Diagnostic.new(
      severity: severity, code: code, message: "Diagnostic message", state: state
    )
  end

  it "preserves its value and copies the diagnostics array" do
    diagnostics = [diagnostic]
    result = described_class.new(value: { payment: 1 }, diagnostics: diagnostics)
    diagnostics << diagnostic(severity: :warning)

    expect(result.value).to eq(payment: 1)
    expect(result.diagnostics.length).to eq(1)
  end

  it "treats warnings and review requests as successful" do
    result = described_class.new(
      diagnostics: [diagnostic(severity: :warning, state: :needs_review)]
    )

    expect(result).to be_success
    expect(result).not_to be_failure
    expect(result).to be_needs_review
  end

  it "treats errors and unresolved diagnostics as failures" do
    error_result = described_class.new(diagnostics: [diagnostic(severity: :error)])
    unresolved_result = described_class.new(
      diagnostics: [diagnostic(severity: :warning, state: :unresolved)]
    )

    expect(error_result).to be_failure
    expect(unresolved_result).to be_failure
    expect(unresolved_result).to be_unresolved
  end

  it "filters diagnostics by severity and blocking state" do
    info = diagnostic(severity: :info, code: :info)
    warning = diagnostic(severity: :warning, code: :warning)
    error = diagnostic(severity: :error, code: :error)
    unresolved = diagnostic(severity: :warning, state: :unresolved, code: :unresolved)
    result = described_class.new(diagnostics: [info, warning, error, unresolved])

    expect(result.infos).to eq([info])
    expect(result.warnings).to eq([warning, unresolved])
    expect(result.errors).to eq([error])
    expect(result.blocking_diagnostics).to eq([error, unresolved])
  end

  it "adds a diagnostic without mutating the original result" do
    original = described_class.new(value: :value)
    added = diagnostic(severity: :warning)
    updated = original.with_diagnostic(added)

    expect(original.diagnostics).to be_empty
    expect(updated.value).to eq(:value)
    expect(updated.diagnostics).to eq([added])
  end

  describe ".success" do
    it "creates a result when diagnostics are non-blocking" do
      result = described_class.success(:value, diagnostics: [diagnostic(severity: :warning)])

      expect(result).to be_success
      expect(result.value).to eq(:value)
    end

    it "rejects blocking diagnostics" do
      expect do
        described_class.success(diagnostics: [diagnostic(severity: :error)])
      end.to raise_error(ArgumentError)
    end
  end

  describe ".failure" do
    it "creates a result with at least one blocking diagnostic" do
      result = described_class.failure(:partial, diagnostics: [diagnostic(state: :unresolved)])

      expect(result).to be_failure
      expect(result.value).to eq(:partial)
    end

    it "rejects diagnostics without a blocking entry" do
      expect do
        described_class.failure(diagnostics: [diagnostic(severity: :warning)])
      end.to raise_error(ArgumentError)
    end
  end

  it "serializes nested core values and diagnostics recursively" do
    value = diagnostic(severity: :info, code: :value)
    warning = diagnostic(severity: :warning)
    result = described_class.new(value: value, diagnostics: [warning])

    expect(result.to_h).to eq(value: value.to_h, diagnostics: [warning.to_h])
  end

  it "implements class-sensitive value equality and a matching hash" do
    warning = diagnostic(severity: :warning)
    first = described_class.new(value: 1, diagnostics: [warning])
    second = described_class.new(value: 1, diagnostics: [warning])

    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
    expect(first).not_to eq(first.to_h)
  end
end
