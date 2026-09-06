# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "compiler pipeline" do
  def compile(spec:, provider:, output:, overrides: nil)
    configuration = ProviderCompiler::Configuration.new(
      spec_path: spec,
      provider_name: provider,
      output_dir: output,
      overrides_path: overrides
    )
    ProviderCompiler::Compiler.new.call(configuration)
  end

  it "runs the official NovaPay document through parse, mapping, generation, verification, and write" do
    Dir.mktmpdir do |root|
      result = compile(
        spec: SpecPaths.fixture("official", "novapay_provider_api.yaml"),
        provider: "novapay_pipeline",
        output: File.join(root, "output")
      )

      expect(result).to be_success
      expect(result.value.fetch("provider_spec").operations.length).to eq(5)
      expect(result.value.fetch("mapping_plan").operations.keys).to contain_exactly(
        "create_request", "fetch_status", "process_callback"
      )
      expect(result.value.fetch("verification")).to include(
        "syntax" => "passed", "fixtures" => "passed", "contract" => "passed"
      )
      expect(Dir.children(File.join(root, "output"))).to contain_exactly(
        "novapay_pipeline_service.rb", "INTEGRATION.md", "fixtures.json"
      )
    end
  end

  it "is deterministic for the same specification, provider name, and decisions" do
    Dir.mktmpdir do |root|
      first = compile(
        spec: SpecPaths.fixture("official", "novapay_provider_api.yaml"),
        provider: "stable_provider",
        output: File.join(root, "one")
      )
      second = compile(
        spec: SpecPaths.fixture("official", "novapay_provider_api.yaml"),
        provider: "stable_provider",
        output: File.join(root, "two")
      )

      expect(first).to be_success
      expect(second).to be_success
      %w[stable_provider_service.rb INTEGRATION.md fixtures.json].each do |filename|
        expect(File.binread(File.join(root, "one", filename))).to eq(File.binread(File.join(root, "two", filename)))
      end
    end
  end

  it "compiles a semantically renamed provider without NovaPay names" do
    Dir.mktmpdir do |root|
      result = compile(
        spec: SpecPaths.fixture("synthetic", "13_novapay_renamed_valid.yaml"),
        provider: "renamed_pipeline",
        output: File.join(root, "output")
      )

      expect(result).to be_success
      source = File.read(File.join(root, "output", "renamed_pipeline_service.rb"), encoding: "UTF-8")
      expect(source).to include("class Provider::RenamedPipelineService < Provider::BaseService")
      expect(source).not_to include("NovapayService")
    end
  end

  it "generates working Bearer, query-api-key, and deeply nested provider variants" do
    providers = {
      "river_pipeline" => "08_riverpay_bearer_query_nested.yaml",
      "pulse_pipeline" => "10_pulsemoney_query_apikey_hmac.yaml",
      "meridian_pipeline" => "11_meridian_nested_objects.yaml"
    }

    Dir.mktmpdir do |root|
      providers.each do |provider, fixture|
        result = compile(
          spec: SpecPaths.fixture("synthetic", fixture),
          provider: provider,
          output: File.join(root, provider)
        )
        expect(result).to be_success, "#{provider}: #{result.diagnostics.map(&:message).join('; ')}"
        expect(result.value.fetch("verification").fetch("scenarios")).to be_a(Hash)
      end
    end
  end

  it "compiles a provider with Basic auth and explicit unknown-requisite decisions" do
    Dir.mktmpdir do |root|
      result = compile(
        spec: SpecPaths.fixture("synthetic", "09_atlasbank_basic_iban_review.yaml"),
        provider: "atlas_pipeline",
        output: File.join(root, "output"),
        overrides: SpecPaths.fixture("overrides", "atlasbank_overrides.yml")
      )

      expect(result).to be_success
      plan = result.value.fetch("mapping_plan")
      expect(plan.field("operation.payout_requisite.iban", direction: :request)).to be_manual
      expect(plan.field("operation.payout_requisite.tax_id", direction: :request)).to be_manual
    end
  end

  it "stops before generation when the required callback role is absent" do
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      result = compile(
        spec: SpecPaths.fixture("synthetic", "12_northstar_missing_callback.yaml"),
        provider: "northstar_pipeline",
        output: output
      )

      expect(result).to be_failure
      expect(result.diagnostics.map(&:code)).to include("operation_mapping_unresolved", "webhook_mapping_unresolved")
      callback_diagnostic = result.diagnostics.find do |diagnostic|
        diagnostic.code == "operation_mapping_unresolved" && diagnostic.location.to_s == "process_callback"
      end
      expect(callback_diagnostic).not_to be_nil
      expect(Dir.exist?(output)).to be(false)
    end
  end
end
