# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Mapping::WebhookMapping do
  let(:operation) do
    ProviderCompiler::Core::API::Operation.new(http_method: "POST", path: "/callbacks")
  end

  it "preserves callback paths" do
    mapping = described_class.new(
      event_path: "event.type",
      status_path: "data.status",
      provider_operation_id_path: "data.payout_id",
      external_id_path: "data.external_id",
      error_path: "data.error"
    )

    expect(mapping.event_path).to eq("event.type")
    expect(mapping.status_path).to eq("data.status")
    expect(mapping.provider_operation_id_path).to eq("data.payout_id")
    expect(mapping.external_id_path).to eq("data.external_id")
    expect(mapping.error_path).to eq("data.error")
  end

  it "is signed when either signature header or algorithm is present" do
    expect(described_class.new).not_to be_signed
    expect(described_class.new(signature_header: "X-Signature")).to be_signed
    expect(described_class.new(signature_algorithm: "HMAC-SHA256")).to be_signed
    expect(described_class.new(signature_header: "")).not_to be_signed
  end

  it "normalizes event keys and looks them up by string or symbol" do
    mapping = described_class.new(events: { completed: "approved", "failed" => :rejected })

    expect(mapping.event_mapping(:completed)).to eq("approved")
    expect(mapping.event_mapping("failed")).to eq(:rejected)
    expect(mapping.event_mapping(:missing)).to be_nil
  end

  it "preserves signature metadata" do
    mapping = described_class.new(
      signature_header: "X-Signature",
      signature_algorithm: "HMAC-SHA256",
      signature_encoding: "hex",
      signed_payload: "raw_body",
      secret_credential_path: "webhook_secret"
    )

    expect(mapping.signature_encoding).to eq("hex")
    expect(mapping.signed_payload).to eq("raw_body")
    expect(mapping.secret_credential_path).to eq("webhook_secret")
  end

  it "serializes its operation, exposes decision helpers, and implements value equality" do
    attributes = { operation: operation, decision: :manual, events: { completed: "approved" } }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first).to be_manual
    expect(described_class.new(decision: :needs_review)).to be_needs_review
    expect(described_class.new(decision: :unresolved)).not_to be_resolved
    expect(first.to_h[:operation]).to eq(operation.to_h)
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
