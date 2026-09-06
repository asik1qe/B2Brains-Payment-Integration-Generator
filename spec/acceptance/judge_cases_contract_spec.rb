# frozen_string_literal: true

require "spec_helper"
require "yaml"

RSpec.describe "judge-case package contract" do
  ROOT = File.expand_path("../..", __dir__)
  JUDGE_ROOT = File.join(ROOT, "judge_cases")
  MANIFEST_PATH = File.join(JUDGE_ROOT, "manifest.yml")

  def manifest
    @manifest ||= YAML.safe_load_file(MANIFEST_PATH, aliases: false)
  end

  it "defines unique, runnable cases with consistent expected CLI outcomes" do
    cases = manifest.fetch("cases")
    expect(cases).not_to be_empty
    expect(cases.map { |item| item.fetch("id") }).to eq(cases.map { |item| item.fetch("id") }.uniq)

    cases.each do |item|
      expected_exit = item.fetch("expected_exit")
      expected_status = item.fetch("expected_status")
      expected_artifacts = item.fetch("expected_artifacts")

      expect([0, 1, 3]).to include(expected_exit)
      expect({ 0 => "SUCCESS", 1 => "FAILED", 3 => "NEEDS REVIEW" }.fetch(expected_exit)).to eq(expected_status)
      expect(expected_artifacts).to eq(expected_exit.zero? ? 3 : 0)
      expect(File).to exist(File.join(JUDGE_ROOT, item.fetch("spec")))
      expect(File).to exist(File.join(JUDGE_ROOT, item.fetch("overrides"))) if item["overrides"]
    end
  end

  it "keeps the judge providers byte-identical to the canonical automated fixtures" do
    pairs = {
      "providers/01_novapay_official.yaml" => "spec/fixtures/official/novapay_provider_api.yaml",
      "providers/02_riverpay_bearer_query_nested.yaml" => "spec/fixtures/synthetic/08_riverpay_bearer_query_nested.yaml",
      "providers/03_atlasbank_basic_review.yaml" => "spec/fixtures/synthetic/09_atlasbank_basic_iban_review.yaml",
      "providers/04_pulsemoney_query_apikey.yaml" => "spec/fixtures/synthetic/10_pulsemoney_query_apikey_hmac.yaml",
      "providers/05_meridian_nested_objects.yaml" => "spec/fixtures/synthetic/11_meridian_nested_objects.yaml",
      "providers/06_northstar_missing_callback.yaml" => "spec/fixtures/synthetic/12_northstar_missing_callback.yaml",
      "providers/07_polaris_ambiguous_operations.yaml" => "spec/fixtures/synthetic/04_polaris_pay_ambiguous_operations.yaml",
      "providers/08_broken_yaml.yaml" => "spec/fixtures/synthetic/07_broken_yaml_intentional.yaml",
      "providers/09_paypal_payouts_public_snapshot.json" => "spec/fixtures/real_world/paypal_payouts_v1_snapshot.json",
      "providers/10_stripe_payouts_public_snapshot.yaml" => "spec/fixtures/real_world/stripe_payouts_snapshot.yaml",
      "providers/11_sumup_payouts_public_snapshot.yaml" => "spec/fixtures/real_world/sumup_payouts_snapshot.yaml"
    }

    pairs.each do |judge_relative, canonical_relative|
      expect(File.binread(File.join(JUDGE_ROOT, judge_relative))).to eq(
        File.binread(File.join(ROOT, canonical_relative))
      ), "judge copy drifted: #{judge_relative}"
    end
  end

  it "pairs every public-source judge case with provenance metadata" do
    public_cases = manifest.fetch("cases").select { |item| item.fetch("id").end_with?("_public") }
    expect(public_cases.map { |item| item.fetch("id") }).to contain_exactly(
      "paypal_public", "stripe_public", "sumup_public"
    )

    source_files = Dir[File.join(JUDGE_ROOT, "sources", "*.source.yml")]
    expect(source_files.length).to eq(public_cases.length)
    source_files.each do |path|
      metadata = YAML.safe_load_file(path, aliases: false)
      expect(metadata.fetch("kind")).to eq("public_openapi_excerpt")
      expect(metadata.fetch("source")).to match(%r{\Ahttps://github\.com/})
      expect(metadata.fetch("license")).not_to be_empty
    end
  end
end
