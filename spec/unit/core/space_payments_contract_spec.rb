# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::SpacePaymentsContract do
  it "defines the four required service methods" do
    expect(described_class::REQUIRED_SERVICE_METHODS).to eq(
      %w[check_conditions create_request process_callback fetch_status]
    )
  end

  it "defines only the three provider operation roles" do
    expect(described_class::OPERATION_ROLES).to eq(
      %w[create_request fetch_status process_callback]
    )
  end

  it "does not treat check_conditions as a provider endpoint role" do
    expect(described_class).to be_required_service_method(:check_conditions)
    expect(described_class).not_to be_operation_role(:check_conditions)
  end

  it "defines the confirmed internal statuses" do
    expect(described_class::INTERNAL_STATUSES).to eq(%w[in_progress approved rejected])
  end

  it "defines the only allowed platform failure codes" do
    expect(described_class::FAILURE_CODES).to eq(%i[
      bad_request unauthorized forbidden unprocessable_entity too_many_requests internal_server_error
    ])
    expect(described_class).to be_failure_code(:unprocessable_entity)
    expect(described_class).not_to be_failure_code(:not_found)
    expect(described_class).not_to be_failure_code(nil)
  end

  it "defines the known operation fields" do
    expect(described_class::KNOWN_OPERATION_FIELDS).to eq(
      %w[amount id provider_operation_key payout_requisite]
    )
    expect(described_class).to be_known_operation_path("operation.payout_requisite.sbp.phone")
    expect(described_class).to be_known_operation_path("operation.payout_requisite.sbp.bank_code")
    expect(described_class).to be_known_operation_path("operation.payout_requisite.sbp.bank_name")
    expect(described_class).to be_known_operation_path("operation.payout_requisite.card_number")
    expect(described_class).not_to be_known_operation_path("operation.payout_requisite.iban")
    expect(described_class).not_to be_known_operation_field("provider_operation_id")
  end

  it "defines the known provider error classes" do
    expect(described_class::KNOWN_PROVIDER_ERRORS).to eq(
      %w[Provider::RateLimitError Provider::UnauthorizedError]
    )
  end

  it "accepts strings and symbols in membership helpers" do
    expect(described_class).to be_required_service_method("create_request")
    expect(described_class).to be_operation_role(:fetch_status)
    expect(described_class).to be_internal_status(:approved)
    expect(described_class).to be_known_operation_field(:amount)
    expect(described_class).to be_known_provider_error(:"Provider::UnauthorizedError")
  end

  it "rejects unknown and provider-specific values" do
    expect(described_class).not_to be_required_service_method(:unknown)
    expect(described_class).not_to be_operation_role(:check_conditions)
    expect(described_class).not_to be_internal_status(:provider_pending)
    expect(described_class).not_to be_known_operation_field(:currency)
    expect(described_class).not_to be_known_provider_error(:"Provider::TimeoutError")
  end
end
