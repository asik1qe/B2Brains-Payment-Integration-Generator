# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "yaml"

RSpec.describe "CLI acceptance matrix" do
  def args(spec, provider, output, *extra)
    ["--spec", spec, "--provider", provider, "--output", output, *extra]
  end

  it "returns SUCCESS and exactly three artifacts for the official NovaPay input" do
    with_tmpdir do |root|
      output = File.join(root, "output")
      code, stdout, stderr = run_cli(args(
        SpecPaths.fixture("official", "novapay_provider_api.yaml"), "novapay_acceptance", output,
        "--non-interactive", "--force"
      ))

      expect(code).to eq(0)
      expect(stderr).to be_empty
      expect(stdout).to include("Status: SUCCESS", "Verification:", "syntax: passed", "contract: passed")
      expect(Dir.children(output)).to contain_exactly("novapay_acceptance_service.rb", "INTEGRATION.md", "fixtures.json")
    end
  end

  it "returns NEEDS REVIEW rather than guessing an ambiguous create operation" do
    with_tmpdir do |root|
      output = File.join(root, "output")
      code, stdout, = run_cli(args(
        SpecPaths.fixture("synthetic", "04_polaris_pay_ambiguous_operations.yaml"),
        "polaris_acceptance", output, "--non-interactive"
      ))

      expect(code).to eq(3)
      expect(stdout).to include("Status: NEEDS REVIEW", "critical_operation_mapping_needs_review")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "returns NEEDS REVIEW for multiple independent unresolved decisions in one document" do
    with_tmpdir do |root|
      code, stdout, = run_cli(args(
        SpecPaths.fixture("synthetic", "14_novapay_multi_review.yaml"),
        "multi_review", File.join(root, "output"), "--non-interactive"
      ))

      expect(code).to eq(3)
      expect(stdout).to include(
        "critical_operation_mapping_needs_review",
        "transformation_incomplete",
        "payout_requisite_mapping_unresolved"
      )
    end
  end

  it "persists an interactive operation decision and reuses it non-interactively" do
    with_tmpdir do |root|
      overrides = File.join(root, "polaris.yml")
      first_output = File.join(root, "first")
      first_code, first_stdout, = run_cli(
        args(
          SpecPaths.fixture("synthetic", "04_polaris_pay_ambiguous_operations.yaml"),
          "polaris_manual", first_output, "--overrides", overrides
        ),
        answers: "n\n1\n",
        interactive: true
      )

      second_code, second_stdout, = run_cli(args(
        SpecPaths.fixture("synthetic", "04_polaris_pay_ambiguous_operations.yaml"),
        "polaris_manual", File.join(root, "second"), "--overrides", overrides,
        "--non-interactive", "--force"
      ))

      expect(first_code).to eq(0)
      expect(first_stdout).to include("Status: SUCCESS")
      expect(second_code).to eq(0)
      expect(second_stdout).to include("Review        not required", "Status: SUCCESS")
    end
  end

  it "fails cleanly when callback is missing and writes no partial artifacts" do
    with_tmpdir do |root|
      output = File.join(root, "output")
      code, stdout, stderr = run_cli(args(
        SpecPaths.fixture("synthetic", "15_novapay_missing_callback.yaml"),
        "missing_callback", output, "--non-interactive"
      ))

      expect(code).to eq(1)
      expect(stdout).to include("Mapping       FAILED")
      expect(stderr).to include("Status: FAILED", "Required callback operation was not found")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "reports malformed YAML without a Ruby stack trace or output" do
    with_tmpdir do |root|
      output = File.join(root, "output")
      code, _stdout, stderr = run_cli(args(
        SpecPaths.fixture("synthetic", "07_broken_yaml_intentional.yaml"),
        "broken_yaml", output, "--non-interactive"
      ))

      expect(code).to eq(1)
      expect(stderr).to include("openapi_parse_error")
      expect(stderr).not_to match(/from .*\.rb:/)
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "accepts JSON OpenAPI through the same complete CLI" do
    with_tmpdir do |root|
      code, stdout, stderr = run_cli(args(
        SpecPaths.fixture("synthetic", "22_riverpay_json.json"),
        "river_json", File.join(root, "output"), "--non-interactive"
      ))

      expect(code).to eq(0)
      expect(stderr).to be_empty
      expect(stdout).to include("OpenAPI       OK", "Status: SUCCESS")
    end
  end

  it "sanitizes provider names that cannot directly form a Ruby constant" do
    with_tmpdir do |root|
      output = File.join(root, "output")
      code, = run_cli(args(
        SpecPaths.fixture("synthetic", "01_aurora_pay_happy_path.yaml"),
        "01-demo-provider", output, "--non-interactive"
      ))

      expect(code).to eq(0)
      source = File.read(Dir[File.join(output, "*_service.rb")].first, encoding: "UTF-8")
      syntax = ProviderCompiler::Verification::SyntaxChecker.new.call(source)
      expect(syntax).to be_success
      expect(source).to include("< Provider::BaseService")
    end
  end

  it "does not overwrite existing output without explicit consent" do
    with_tmpdir do |root|
      output = File.join(root, "output")
      base_args = args(
        SpecPaths.fixture("synthetic", "01_aurora_pay_happy_path.yaml"),
        "overwrite_guard", output
      )
      expect(run_cli([*base_args, "--non-interactive"]).first).to eq(0)
      service = Dir[File.join(output, "*_service.rb")].first
      before = File.binread(service)

      code, stdout, stderr = run_cli(base_args, answers: "n\n", interactive: true)

      expect(code).to eq(1)
      expect(stdout).to include("Overwrite?")
      expect(stderr).to include("Output was not overwritten")
      expect(File.binread(service)).to eq(before)
    end
  end
end
