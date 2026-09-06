# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Mapping::ErrorMapping do
  it "normalizes operation role and HTTP status without changing codes or paths" do
    mapping = described_class.new(
      operation_role: :create_request,
      http_status: 429,
      provider_code: :rate_limit_exceeded,
      provider_code_path: "error.code",
      message_path: "error.message"
    )

    expect(mapping.operation_role).to eq("create_request")
    expect(mapping.http_status).to eq("429")
    expect(mapping.provider_code).to eq(:rate_limit_exceeded)
    expect(mapping.provider_code_path).to eq("error.code")
  end

  it "matches integer and string HTTP statuses and does not make nil a wildcard" do
    mapping = described_class.new(http_status: 422)

    expect(mapping).to be_matches_http_status(422)
    expect(mapping).to be_matches_http_status("422")
    expect(mapping).not_to be_matches_http_status(400)
    expect(described_class.new).not_to be_matches_http_status(nil)
  end

  it "preserves retry configuration" do
    mapping = described_class.new(retryable: true, retry_after_header: "Retry-After")

    expect(mapping).to be_retryable
    expect(mapping.retry_after_header).to eq("Retry-After")
  end

  it "exposes decision helpers" do
    expect(described_class.new(decision: :AUTO)).to be_auto
    expect(described_class.new(decision: :needs_review)).to be_needs_review
    expect(described_class.new(decision: :manual)).to be_manual
    expect(described_class.new(decision: :unresolved)).not_to be_resolved
  end

  it "keeps a stable representation and implements value equality" do
    attributes = { target: :validation, retryable: false, evidence: ["HTTP 422"] }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.to_h).to include(target: :validation, retryable: false, decision: "auto")
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
