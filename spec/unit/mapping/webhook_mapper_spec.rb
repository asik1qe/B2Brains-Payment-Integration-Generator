# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Mapping::WebhookMapper do
  subject(:mapper) { described_class.new }

  it "extracts callback paths, signature header, algorithm, and event mappings" do
    operation = synthetic_provider_spec.operations.last
    webhook = mapper.call(operation)

    expect(webhook.event_path).to eq("event")
    expect(webhook.status_path).to eq("state")
    expect(webhook.provider_operation_id_path).to eq("transaction_id")
    expect(webhook.external_id_path).to eq("reference_id")
    expect(webhook.error_path).to eq("failure")
    expect(webhook.signature_header).to eq("Digest-Signature")
    expect(webhook.signature_algorithm).to eq("HMAC-SHA512")
    expect(webhook.event_mapping("transaction.succeeded")).to eq("approved")
  end

  it "does not infer encoding, signed payload, or secret from a signature description" do
    webhook = mapper.call(synthetic_provider_spec.operations.last)

    expect(webhook).to be_signed
    expect(webhook.signature_encoding).to be_nil
    expect(webhook.signed_payload).to be_nil
    expect(webhook.secret_credential_path).to be_nil
    expect(webhook).to be_needs_review
    expect(mapper.diagnostics.map(&:code)).to include("webhook_mapping_needs_review")
  end

  it "keeps an unsigned complete callback automatic" do
    original = synthetic_provider_spec.operations.last
    operation = api_operation(
      method: :post,
      path: original.path,
      operation_id: original.operation_id,
      request_schema: original.request_body.schema,
      responses: original.responses,
      security: []
    )
    webhook = mapper.call(operation)

    expect(webhook).not_to be_signed
    expect(webhook).to be_auto
    expect(mapper.diagnostics).to be_empty
  end

  it "returns unresolved when no callback operation exists" do
    expect(mapper.call(nil)).to be_nil
    expect(mapper.diagnostics.first.code).to eq("webhook_mapping_unresolved")
  end


  it "recognizes a disbursement id in callback payloads" do
    operation = input_provider_spec("06_vector_bank_unknown_requisites.yaml").operations.find do |candidate|
      candidate.path == "/webhooks/disbursement"
    end

    webhook = mapper.call(operation)

    expect(webhook.provider_operation_id_path).to eq("disbursement_id")
    expect(mapper.diagnostics.map(&:code)).not_to include("webhook_mapping_needs_review")
  end
end
