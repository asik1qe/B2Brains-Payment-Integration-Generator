# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe ProviderCompiler::CLI::Presenter do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  subject(:presenter) { described_class.new(out: out, err: err) }

  def diagnostic(severity:, code:, message:, location: nil, state: nil, metadata: {})
    ProviderCompiler::Core::Diagnostic.new(
      severity: severity, code: code, message: message, location: location,
      stage: :test, state: state, metadata: metadata
    )
  end

  def success_result(diagnostics: [])
    ProviderCompiler::Core::Result.success(
      {
        "written_files" => {
          "service.rb" => "C:/build/service.rb",
          "INTEGRATION.md" => "C:/build/INTEGRATION.md",
          "fixtures.json" => "C:/build/fixtures.json"
        },
        "verification" => {
          "syntax" => "passed", "fixtures" => "passed", "contract" => "passed",
          "scenarios" => { "create_request" => "passed", "webhook_signature" => "skipped" }
        }
      },
      diagnostics: diagnostics
    )
  end

  it "prints success, generated paths, and verification summary" do
    config = ProviderCompiler::Configuration.new(spec_path: "api.yml", provider_name: "orbit")

    presenter.present(success_result, configuration: config)

    expect(out.string).to include(
      "Provider: orbit", "Status: SUCCESS", "C:/build/service.rb",
      "syntax: passed", "fixtures: passed", "contract: passed", "skipped: webhook_signature"
    )
    expect(err.string).to be_empty
  end

  it "prints warnings on success" do
    warning = diagnostic(
      severity: :warning, code: :review_needed, message: "Review mapping", state: :needs_review
    )

    presenter.present(success_result(diagnostics: [warning]))

    expect(out.string).to include("Warnings:", "warning review_needed: Review mapping")
  end

  it "prints failures and useful locations to stderr" do
    error = diagnostic(
      severity: :error, code: :mapping_failed, message: "Could not map", location: "create_request", state: :unresolved
    )
    result = ProviderCompiler::Core::Result.failure(nil, diagnostics: [error])

    presenter.present(result)

    expect(err.string).to include("Status: FAILED", "error mapping_failed: Could not map [create_request]")
    expect(out.string).to be_empty
  end

  it "does not print diagnostic metadata" do
    error = diagnostic(
      severity: :error, code: :failed, message: "Safe message", state: :unresolved,
      metadata: { "api_key" => "super-secret-value", "huge" => "x" * 5000 }
    )
    result = ProviderCompiler::Core::Result.failure(nil, diagnostics: [error])

    presenter.failure(result)

    expect(err.string).not_to include("super-secret-value", "x" * 100)
  end

  it "redacts credential-like values from messages" do
    presenter.internal_error("api_key=super-secret-value")

    expect(err.string).to include("api_key=[REDACTED]")
    expect(err.string).not_to include("super-secret-value")
  end
end
