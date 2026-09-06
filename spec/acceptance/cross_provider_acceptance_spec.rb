# frozen_string_literal: true

require "spec_helper"

RSpec.describe "cross-provider acceptance" do
  CASES = {
    "RiverPay Bearer + query status + nested response" => ["08_riverpay_bearer_query_nested.yaml", nil],
    "PulseMoney query API key + HMAC metadata" => ["10_pulsemoney_query_apikey_hmac.yaml", nil],
    "Meridian deep nested request/response/callback" => ["11_meridian_nested_objects.yaml", nil],
    "AtlasBank Basic auth + manual bank requisites" => ["09_atlasbank_basic_iban_review.yaml", "atlasbank_overrides.yml"]
  }.freeze

  CASES.each do |label, (fixture, override)|
    it "compiles #{label}" do
      with_tmpdir do |root|
        argv = [
          "--spec", SpecPaths.fixture("synthetic", fixture),
          "--provider", label.downcase.gsub(/[^a-z0-9]+/, "_"),
          "--output", File.join(root, "output"),
          "--non-interactive",
          "--force"
        ]
        argv += ["--overrides", SpecPaths.fixture("overrides", override)] if override
        code, stdout, stderr = run_cli(argv)

        expect(code).to eq(0), stderr
        expect(stdout).to include("Status: SUCCESS", "Generation    OK", "Verification  OK")
      end
    end
  end

  it "fails safely for a structurally incomplete provider" do
    with_tmpdir do |root|
      code, stdout, stderr = run_cli([
        "--spec", SpecPaths.fixture("synthetic", "12_northstar_missing_callback.yaml"),
        "--provider", "northstar_incomplete",
        "--output", File.join(root, "output"),
        "--non-interactive"
      ])

      expect(code).to eq(1)
      expect(stdout).to include("Mapping       FAILED")
      expect(stderr).to include("Required callback operation was not found")
    end
  end
end
