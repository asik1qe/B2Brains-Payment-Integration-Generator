# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "support"

RSpec.describe ProviderCompiler::Generation::ServiceGenerator do
  subject(:generator) { described_class.new }

  it "rejects unresolved plans before rendering" do
    diagnostic = ProviderCompiler::Core::Diagnostic.new(
      severity: :error,
      code: :field_mapping_unresolved,
      message: "missing",
      stage: :mapping,
      state: :unresolved
    )
    plan = ProviderCompiler::Core::Mapping::MappingPlan.new(provider_name: "Broken", diagnostics: [diagnostic])
    result = generator.call(mapping_plan: plan)

    expect(result).to be_failure
    expect(result.value).to be_nil
    expect(result.diagnostics.map(&:code)).to include("mapping_plan_unresolved")
  end

  it "rejects a missing provider name" do
    plan = ProviderCompiler::Core::Mapping::MappingPlan.new
    result = generator.call(mapping_plan: plan)

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("provider_name_missing")
  end

  it "builds a GeneratedIntegration with deterministic filenames and JSON" do
    first = generator.call(mapping_plan: orbit_mapping_plan, provider_spec: synthetic_provider_spec)
    second = generator.call(mapping_plan: orbit_mapping_plan, provider_spec: synthetic_provider_spec)

    expect(first).to be_success
    expect(first.value).to be_a(ProviderCompiler::Core::GeneratedIntegration)
    expect(first.value.service_filename).to eq("orbit_transfer_api_service.rb")
    expect(first.value.metadata["class_name"]).to eq("OrbitTransferApiService")
    expect(first.value.files.keys).to contain_exactly("orbit_transfer_api_service.rb", "INTEGRATION.md", "fixtures.json")
    expect { JSON.parse(first.value.fixtures_json) }.not_to raise_error
    expect(second.value.files).to eq(first.value.files)
    expect(first.diagnostics.map(&:code)).to include("money_unit_needs_review", "webhook_mapping_needs_review")
  end

  it "calls all three subgenerators" do
    renderer = instance_double(ProviderCompiler::Generation::ServiceRenderer, diagnostics: [])
    documentation = instance_double(ProviderCompiler::Generation::DocumentationGenerator)
    fixtures = instance_double(ProviderCompiler::Generation::FixturesGenerator)
    allow(renderer).to receive(:render).and_return("service\n")
    allow(documentation).to receive(:generate).and_return("docs\n")
    allow(fixtures).to receive(:generate).and_return("fixture" => true)
    generator = described_class.new(
      service_renderer: renderer,
      documentation_generator: documentation,
      fixtures_generator: fixtures
    )

    result = generator.call(mapping_plan: orbit_mapping_plan, provider_spec: synthetic_provider_spec)

    expect(result).to be_success
    expect(renderer).to have_received(:render).once
    expect(documentation).to have_received(:generate).once
    expect(fixtures).to have_received(:generate).once
  end


  it "does not generate artifacts for a required unknown payout requisite" do
    provider = input_provider_spec("02_orbit_cash_renamed_but_clear.yaml")
    plan = ProviderCompiler::Mapping::Mapper.new.call(provider).value

    result = generator.call(mapping_plan: plan, provider_spec: provider)

    expect(result).to be_failure
    expect(result.value).to be_nil
    expect(result.diagnostics.map(&:code)).to include(
      "payout_requisite_mapping_unresolved", "mapping_plan_unresolved"
    )
  end

  it "generates an unknown provider field only from its confirmed manual source" do
    provider = input_provider_spec("02_orbit_cash_renamed_but_clear.yaml")
    override = SpecPaths.fixture("overrides", "orbit_cash_overrides.yml")
    plan = ProviderCompiler::Mapping::Mapper.new.call(provider, overrides: override).value

    result = generator.call(mapping_plan: plan, provider_spec: provider)
    fixtures = JSON.parse(result.value.fixtures_json)

    expect(result).to be_success
    expect(result.value.service_code).to include(
      '"card" => dig_value(operation.payout_requisite, "card_number")'
    )
    expect(result.value.service_code).not_to include(
      'dig_value(operation.payout_requisite, "card")'
    )
    expect(fixtures.dig("create_request", "operation", "payout_requisite")).to eq(
      "card_number" => "string"
    )
  end

  describe "NovaPay golden pipeline" do
    let(:result) { generator.call(mapping_plan: novapay_mapping_plan, provider_spec: novapay_provider_spec) }

    it "matches all three golden artifacts" do
      expect(result).to be_success
      result.value.files.each do |filename, content|
        golden_path = SpecPaths.fixture("golden", "novapay", filename)
        expected = File.binread(golden_path)
        if filename == "INTEGRATION.md"
          expected += "\n" if filename == "INTEGRATION.md" && !expected.end_with?("\n\n")
        end
        expect(content.b).to eq(expected), "golden mismatch: #{filename}"
      end
    end

    it "produces syntactically valid NovaPay Ruby" do
      expect { RubyVM::InstructionSequence.compile(result.value.service_code) }.not_to raise_error
      expect(result.value.service_code).to include(
        "POST".downcase,
        'class Provider::NovaPayPayoutApiService < Provider::BaseService',
        'BASE_URL = ENV.fetch("NOVA_PAY_PAYOUT_API_BASE_URL"',
        'url = build_url("/payouts")',
        'url = build_url("/payouts/#{operation.provider_operation_key}")',
        '"currency" => "RUB"',
        '"external_id" => (operation.id.nil? ? nil : operation.id.to_s)',
        'headers["X-API-Key"]',
        'failure(:unauthorized, "provider_compiler.errors.unauthorized"',
        'failure(:too_many_requests, "provider_compiler.errors.too_many_requests"'
      )
    end
  end

  it "sanitizes provider names that cannot start a Ruby constant" do
    source = orbit_mapping_plan
    plan = ProviderCompiler::Core::Mapping::MappingPlan.new(
      provider_name: "01 provider",
      operations: source.operations,
      fields: source.fields,
      statuses: source.statuses,
      errors: source.errors,
      security: source.security,
      webhook: source.webhook,
      conditions: source.conditions,
      diagnostics: source.diagnostics,
      metadata: source.metadata
    )

    result = generator.call(mapping_plan: plan, provider_spec: synthetic_provider_spec)

    expect(result).to be_success
    expect(result.value.service_filename).to eq("provider_01_provider_service.rb")
    expect(result.value.service_code).to include(
      "class Provider::Provider01ProviderService < Provider::BaseService"
    )
    expect { RubyVM::InstructionSequence.compile(result.value.service_code) }.not_to raise_error
  end
end
