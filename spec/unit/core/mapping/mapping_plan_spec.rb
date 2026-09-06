# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::Mapping::MappingPlan do
  let(:operation) do
    ProviderCompiler::Core::API::Operation.new(http_method: "POST", path: "/payments")
  end
  let(:operation_mapping) do
    ProviderCompiler::Core::Mapping::OperationMapping.new(role: :create_request, operation: operation)
  end
  let(:request_field) do
    ProviderCompiler::Core::Mapping::FieldMapping.new(
      internal_path: "operation.amount", provider_path: "amount", direction: :request
    )
  end
  let(:response_field) do
    ProviderCompiler::Core::Mapping::FieldMapping.new(
      internal_path: "operation.id", provider_path: "id", direction: :response
    )
  end

  it "preserves all plan sections and normalizes operation keys" do
    statuses = ProviderCompiler::Core::Mapping::StatusMapping.new(mappings: { done: "approved" })
    security = ProviderCompiler::Core::Mapping::SecurityMapping.new(type: "bearer")
    webhook = ProviderCompiler::Core::Mapping::WebhookMapping.new(events: { done: "approved" })
    plan = described_class.new(
      provider_name: "Provider",
      operations: { create_request: operation_mapping },
      fields: [request_field],
      statuses: statuses,
      security: security,
      webhook: webhook,
      conditions: [{ field: "amount" }],
      metadata: { source: "manual" }
    )

    expect(plan.operations).to eq("create_request" => operation_mapping)
    expect(plan.statuses).to equal(statuses)
    expect(plan.security).to equal(security)
    expect(plan.webhook).to equal(webhook)
    expect(plan.conditions).to eq([{ field: "amount" }])
  end

  it "looks operations up by strings and symbols" do
    plan = described_class.new(operations: { create_request: operation_mapping })

    expect(plan.operation(:create_request)).to equal(operation_mapping)
    expect(plan.operation("create_request")).to equal(operation_mapping)
  end

  it "looks fields up by internal path and optional direction" do
    plan = described_class.new(fields: [request_field, response_field])

    expect(plan.field("operation.amount")).to equal(request_field)
    expect(plan.field("operation.id", direction: :RESPONSE)).to equal(response_field)
    expect(plan.field("operation.id", direction: :request)).to be_nil
  end

  it "returns fields for a case-insensitive direction" do
    plan = described_class.new(fields: [request_field, response_field])

    expect(plan.fields_for(:REQUEST)).to eq([request_field])
    expect(plan.fields_for("response")).to eq([response_field])
  end

  it "returns operation-specific and general error mappings" do
    general = ProviderCompiler::Core::Mapping::ErrorMapping.new(http_status: 500)
    create = ProviderCompiler::Core::Mapping::ErrorMapping.new(
      operation_role: :create_request, http_status: 422
    )
    fetch = ProviderCompiler::Core::Mapping::ErrorMapping.new(
      operation_role: :fetch_status, http_status: 404
    )
    plan = described_class.new(errors: [general, create, fetch])

    expect(plan.error_mappings_for(:create_request)).to eq([general, create])
  end

  it "is unresolved only for explicit error severity or unresolved state diagnostics" do
    diagnostic_class = Struct.new(:severity, :state)

    expect(described_class.new).to be_resolved
    expect(described_class.new(diagnostics: [{ severity: "warning" }])).to be_resolved
    expect(described_class.new(diagnostics: [{ "severity" => "error" }])).not_to be_resolved
    expect(described_class.new(diagnostics: [{ state: :unresolved }])).not_to be_resolved
    expect(described_class.new(diagnostics: [diagnostic_class.new("ERROR", nil)])).not_to be_resolved
  end

  it "does not change when caller-owned collections are mutated" do
    operations = { create_request: operation_mapping }
    fields = [request_field]
    conditions = [{ rule: { enabled: true } }]
    metadata = { context: { reviewed: false } }
    plan = described_class.new(
      operations: operations, fields: fields, conditions: conditions, metadata: metadata
    )

    operations[:fetch_status] = operation_mapping
    fields << response_field
    conditions.first[:rule][:enabled] = false
    metadata[:context][:reviewed] = true

    expect(plan.operations.keys).to eq(["create_request"])
    expect(plan.fields).to eq([request_field])
    expect(plan.conditions).to eq([{ rule: { enabled: true } }])
    expect(plan.metadata).to eq(context: { reviewed: false })
  end

  it "recursively serializes mapping and API objects and implements value equality" do
    attributes = { provider_name: "Provider", operations: { create_request: operation_mapping },
                   fields: [request_field] }
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.to_h[:operations]["create_request"]).to eq(operation_mapping.to_h)
    expect(first.to_h[:fields]).to eq([request_field.to_h])
    expect(first.to_h).to include(statuses: nil, errors: [], diagnostics: [], metadata: {})
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
