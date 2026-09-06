# frozen_string_literal: true

require "spec_helper"
require "yaml"

RSpec.describe "public payment-provider OpenAPI compatibility" do
  PROVIDERS = {
    "PayPal Payouts" => {
      spec: "paypal_payouts_v1_snapshot.json",
      source: "paypal_payouts_v1_snapshot.source.yml",
      min_operations: 2,
      expected_boundary_codes: %w[
        security_scheme_unsupported security_mapping_unresolved
        callback_operation_unresolved webhook_mapping_unresolved
        critical_operation_mapping_needs_review operation_mapping_unresolved
      ]
    },
    "Stripe Payouts" => {
      spec: "stripe_payouts_snapshot.yaml",
      source: "stripe_payouts_snapshot.source.yml",
      min_operations: 2,
      expected_boundary_codes: %w[
        non_json_content_unsupported critical_request_media_type_unsupported
        callback_operation_unresolved webhook_mapping_unresolved operation_mapping_unresolved
      ]
    },
    "SumUp Payouts" => {
      spec: "sumup_payouts_snapshot.yaml",
      source: "sumup_payouts_snapshot.source.yml",
      min_operations: 1,
      expected_boundary_codes: %w[
        operation_mapping_unresolved callback_operation_unresolved
        webhook_mapping_unresolved status_mapping_unresolved
      ]
    }
  }.freeze

  PROVIDERS.each do |label, config|
    it "loads and parses the #{label} public OpenAPI excerpt without network access" do
      source_metadata = YAML.safe_load(
        File.read(SpecPaths.fixture("real_world", config.fetch(:source)), encoding: "UTF-8"),
        aliases: false
      )
      expect(source_metadata.fetch("provider")).not_to be_empty
      expect(source_metadata.fetch("source")).to match(%r{\Ahttps://})
      expect(source_metadata.fetch("kind")).to eq("public_openapi_excerpt")

      loaded = ProviderCompiler::OpenAPI::Loader.new.call(
        SpecPaths.fixture("real_world", config.fetch(:spec))
      )
      expect(loaded).to be_success

      parsed = ProviderCompiler::OpenAPI::Parser.new.call(loaded.value)
      expect(parsed).to be_success
      expect(parsed.value.operations.length).to be >= config.fetch(:min_operations)
      expect(parsed.value.servers).not_to be_empty
    end


    it "stops the complete compiler before generation for #{label} when the Space Payments contract is not satisfied" do
      with_tmpdir do |root|
        output = File.join(root, "output")
        code, _stdout, _stderr = run_cli([
          "--spec", SpecPaths.fixture("real_world", config.fetch(:spec)),
          "--provider", label.downcase.gsub(/[^a-z0-9]+/, "_"),
          "--output", output,
          "--non-interactive",
          "--force"
        ])

        expect([1, 3]).to include(code)
        expect(Dir.exist?(output)).to be(false)
      end
    end
    it "reaches a safe explicit compatibility boundary for #{label} instead of guessing" do
      loaded = ProviderCompiler::OpenAPI::Loader.new.call(
        SpecPaths.fixture("real_world", config.fetch(:spec))
      )
      parsed = ProviderCompiler::OpenAPI::Parser.new.call(loaded.value)
      mapped = ProviderCompiler::Mapping::Mapper.new.call(parsed.value)

      expect(mapped).to be_failure
      codes = (parsed.diagnostics + mapped.diagnostics).map(&:code)
      expect(codes & config.fetch(:expected_boundary_codes)).not_to be_empty
    end
  end

  it "keeps every external excerpt paired with explicit provenance metadata" do
    excerpts = Dir[SpecPaths.fixture("real_world", "*")]
                    .reject { |path| path.end_with?(".source.yml") }
                    .select { |path| File.file?(path) }

    expect(excerpts).not_to be_empty
    excerpts.each do |excerpt|
      basename = File.basename(excerpt).sub(/\.(?:yaml|yml|json)\z/, "")
      source_file = SpecPaths.fixture("real_world", "#{basename}.source.yml")
      expect(File).to exist(source_file), "missing provenance for #{File.basename(excerpt)}"
    end
  end
end
