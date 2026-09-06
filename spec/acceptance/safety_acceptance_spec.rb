# frozen_string_literal: true

require "spec_helper"

RSpec.describe "safe failure acceptance matrix" do
  def run_fixture(name, provider: "safety_case")
    with_tmpdir do |root|
      output = File.join(root, "output")
      code, stdout, stderr = run_cli([
        "--spec", SpecPaths.fixture("synthetic", name),
        "--provider", provider,
        "--output", output,
        "--non-interactive"
      ])
      yield code, stdout, stderr, output
    end
  end

  it "blocks ambiguous outbound authentication until a scheme is selected" do
    run_fixture("16_ambiguous_security.yaml") do |code, stdout, _stderr, output|
      expect(code).to eq(3)
      expect(stdout).to include("security_mapping_needs_review", "Status: NEEDS REVIEW")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "blocks composition on a selected create schema" do
    run_fixture("17_critical_oneof.yaml") do |code, _stdout, stderr, output|
      expect(code).to eq(1)
      expect(stderr).to include("critical_schema_composition_unsupported")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "does not block an unsupported composition used only by an unrelated endpoint" do
    run_fixture("18_irrelevant_oneof.yaml", provider: "irrelevant_composition") do |code, stdout, _stderr, output|
      expect(code).to eq(0)
      expect(stdout).to include("Status: SUCCESS")
      expect(Dir.exist?(output)).to be(true)
    end
  end

  it "blocks a required non-JSON create body" do
    run_fixture("19_xml_only_create.yaml") do |code, _stdout, stderr, output|
      expect(code).to eq(1)
      expect(stderr).to include("critical_request_media_type_unsupported")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "does not silently ignore an operation-specific server" do
    run_fixture("20_operation_server_override.yaml") do |code, _stdout, stderr, output|
      expect(code).to eq(1)
      expect(stderr).to include("critical_operation_servers_unsupported")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "rejects an external ref without trying to fetch the network" do
    run_fixture("21_external_ref.yaml") do |code, _stdout, stderr, output|
      expect(code).to eq(1)
      expect(stderr).to include("external_ref_unsupported")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "distinguishes reviewable ambiguity from fatal unsupported input by exit code" do
    run_fixture("04_polaris_pay_ambiguous_operations.yaml", provider: "review_exit") do |review_code, _stdout, _stderr, _output|
      expect(review_code).to eq(3)
    end
    run_fixture("12_northstar_missing_callback.yaml", provider: "fatal_exit") do |fatal_code, _stdout, _stderr, _output|
      expect(fatal_code).to eq(1)
    end
  end
end
