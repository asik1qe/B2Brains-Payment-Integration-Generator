# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "yaml"
require "json"
require "fileutils"

RSpec.describe "interactive compiler CLI" do
  def fixture(name)
    SpecPaths.fixture("synthetic", name)
  end

  def run_cli(argv, answers: "", interactive: true)
    out = StringIO.new
    err = StringIO.new
    presenter = ProviderCompiler::CLI::Presenter.new(out: out, err: err)
    command = ProviderCompiler::CLI::Command.new(
      presenter: presenter, input: StringIO.new(answers), interactive: interactive
    )
    [command.run(argv), out.string, err.string]
  end

  it "returns NEEDS REVIEW without generating in non-interactive mode" do
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      code, out, = run_cli([
        "--spec", fixture("02_orbit_cash_renamed_but_clear.yaml"), "--provider", "orbit",
        "--output", output, "--non-interactive"
      ], interactive: false)

      expect(code).to eq(3)
      expect(out).to include("Status: NEEDS REVIEW", "beneficiary.card")
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "shows source only after y, returns to choice, saves Orbit decision, and succeeds" do
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      overrides = File.join(root, "orbit.yml")
      code, out, err = run_cli([
        "--spec", fixture("02_orbit_cash_renamed_but_clear.yaml"), "--provider", "orbit",
        "--output", output, "--overrides", overrides
      ], answers: "y\n1\n")

      expect(code).to eq(0)
      expect(err).to be_empty
      expect(out.index("Candidates:")).to be < out.index("Show original OpenAPI fragment?")
      expect(out.index("OpenAPI source:")).to be < out.index("Choose:")
      expect(out).to include("[2/5] Mapping       OK", "Status: SUCCESS")
      expect(YAML.safe_load_file(overrides).dig("fields", "operation.payout_requisite.card_number", "provider_path"))
        .to eq("beneficiary.card")
      service = File.join(output, "orbit_service.rb")
      expect(File.read(service)).to include('dig_value(operation.payout_requisite, "card_number")')
      expect(File.read(service)).not_to include('dig_value(operation.payout_requisite, "card")')
    end
  end

  it "does not reveal source for Enter and resolves the Quartz money factor" do
    Dir.mktmpdir do |root|
      overrides = File.join(root, "quartz.yml")
      code, out, = run_cli([
        "--spec", fixture("03_quartz_finance_query_status.yaml"), "--provider", "quartz",
        "--output", File.join(root, "output"), "--overrides", overrides
      ], answers: "\n100\n")

      expect(code).to eq(0)
      expect(out).not_to include("OpenAPI source:")
      expect(YAML.safe_load_file(overrides).dig("fields", "operation.amount", "transformation", "factor")).to eq(100)
    end
  end

  it "shows the relevant money description only when requested" do
    Dir.mktmpdir do |root|
      code, out, = run_cli([
        "--spec", fixture("03_quartz_finance_query_status.yaml"), "--provider", "quartz_preview",
        "--output", File.join(root, "output"), "--overrides", File.join(root, "mapping.yml")
      ], answers: "y\n100\n")

      expect(code).to eq(0)
      expect(out).to include("OpenAPI source:", "description: Amount in minor units", "Enter integer factor:")
      expect(out.index("OpenAPI source:")).to be < out.index("Enter integer factor:")
    end
  end

  it "shows operation candidates and persists the Polaris selection" do
    Dir.mktmpdir do |root|
      overrides = File.join(root, "polaris.yml")
      code, out, = run_cli([
        "--spec", fixture("04_polaris_pay_ambiguous_operations.yaml"), "--provider", "polaris_pay",
        "--output", File.join(root, "output"), "--overrides", overrides
      ], answers: "n\n1\n")

      expect(code).to eq(0)
      expect(out).to include("POST /payments", "POST /transfers", "Suggested:")
      expect(out).not_to include("OpenAPI source:")
      expect(YAML.safe_load_file(overrides).dig("operations", "create_request", "path")).to eq("/payments")
    end
  end

  it "retries invalid operation choices and nonexistent manual endpoints" do
    Dir.mktmpdir do |root|
      answers = ["n", "8", "m", "POST", "/missing", "POST", "/payments"].join("\n") + "\n"
      code, out, = run_cli([
        "--spec", fixture("04_polaris_pay_ambiguous_operations.yaml"), "--provider", "polaris_manual",
        "--output", File.join(root, "output"), "--overrides", File.join(root, "mapping.yml")
      ], answers: answers)

      expect(code).to eq(0)
      expect(out).to include("Choose a candidate number", "Operation not found in OpenAPI", "Try again")
    end
  end

  it "automatically shows source preview in debug without consuming an answer" do
    Dir.mktmpdir do |root|
      code, out, = run_cli([
        "--spec", fixture("02_orbit_cash_renamed_but_clear.yaml"), "--provider", "orbit_debug",
        "--output", File.join(root, "output"), "--overrides", File.join(root, "mapping.yml"), "--debug"
      ], answers: "1\n")

      expect(code).to eq(0)
      expect(out).to include("OpenAPI source:", "[DEBUG]", "Mapping: rerun after saved decision")
      expect(out).not_to include("Show original OpenAPI fragment?")
    end
  end

  it "stops cleanly on EOF and leaves no generated output" do
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      code, = run_cli([
        "--spec", fixture("02_orbit_cash_renamed_but_clear.yaml"), "--provider", "orbit",
        "--output", output, "--overrides", File.join(root, "mapping.yml")
      ])

      expect(code).to eq(1)
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "prompts for all missing startup values and accepts the default output" do
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        code, out, = run_cli([], answers: "#{fixture('01_aurora_pay_happy_path.yaml')}\naurora_wizard\n\n")

        expect(code).to eq(0)
        expect(out).to include("OpenAPI file:", "Provider name:", "Output directory [./output]:")
        expect(Dir.children(File.join(root, "output"))).to contain_exactly(
          "aurora_wizard_service.rb", "INTEGRATION.md", "fixtures.json"
        )
      end
    end
  end

  it "lets an interactive user correct an invalid spec path" do
    Dir.mktmpdir do |root|
      output = File.join(root, "generated")
      answers = "missing.yml\n#{fixture('01_aurora_pay_happy_path.yaml')}\naurora_retry\n#{output}\n"

      code, out, = run_cli([], answers: answers)

      expect(code).to eq(0)
      expect(out).to include("OpenAPI file not found. Try again")
    end
  end

  it "treats q during startup as a clean user abort" do
    code, _out, err = run_cli([], answers: "q\n")

    expect(code).to eq(1)
    expect(err).to include("Aborted by user", "No generated files were written")
    expect(err).not_to include("Usage error")
  end

  it "retries an invalid money factor instead of failing" do
    Dir.mktmpdir do |root|
      code, out, = run_cli([
        "--spec", fixture("03_quartz_finance_query_status.yaml"), "--provider", "quartz_retry",
        "--output", File.join(root, "output"), "--overrides", File.join(root, "mapping.yml")
      ], answers: "n\nabc\n100\n")

      expect(code).to eq(0)
      expect(out).to include("Factor must be a positive integer.")
    end
  end

  it "reuses a default Orbit override on the next non-interactive run" do
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        first_code, = run_cli([
          "--spec", fixture("02_orbit_cash_renamed_but_clear.yaml"), "--provider", "orbit_reuse",
          "--output", File.join(root, "first")
        ], answers: "n\n1\n")
        second_code, second_out, = run_cli([
          "--spec", fixture("02_orbit_cash_renamed_but_clear.yaml"), "--provider", "orbit_reuse",
          "--output", File.join(root, "second"), "--non-interactive"
        ], interactive: false)

        expect(first_code).to eq(0)
        expect(second_code).to eq(0)
        expect(second_out).to include("Overrides:", ".provider-compiler/orbit_reuse.overrides.yml")
        expect(second_out).not_to include("Status: NEEDS REVIEW", "REVIEW 1/")
      end
    end
  end

  it "reuses a default Polaris operation override without asking again" do
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        first_code, = run_cli([
          "--spec", fixture("04_polaris_pay_ambiguous_operations.yaml"), "--provider", "polaris_reuse",
          "--output", File.join(root, "first")
        ], answers: "n\n1\n")
        second_code, second_out, = run_cli([
          "--spec", fixture("04_polaris_pay_ambiguous_operations.yaml"), "--provider", "polaris_reuse",
          "--output", File.join(root, "second"), "--non-interactive"
        ], interactive: false)

        expect(first_code).to eq(0)
        expect(second_code).to eq(0)
        expect(second_out).to include(".provider-compiler/polaris_reuse.overrides.yml")
        expect(second_out).not_to include("Status: NEEDS REVIEW", "REVIEW 1/")
      end
    end
  end

  it "keeps existing output unchanged when overwrite is declined" do
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      args = [
        "--spec", fixture("01_aurora_pay_happy_path.yaml"), "--provider", "aurora_safe", "--output", output
      ]
      expect(run_cli(args, interactive: false).first).to eq(0)
      service = File.join(output, "aurora_safe_service.rb")
      before = File.binread(service)

      code, out, err = run_cli(args, answers: "n\n")

      expect(code).to eq(1)
      expect(out).to include("Output already contains generated files", "Overwrite? [y/N]")
      expect(err).to include("Output was not overwritten")
      expect(File.binread(service)).to eq(before)
    end
  end

  it "uses force to overwrite without reading stdin" do
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      args = [
        "--spec", fixture("01_aurora_pay_happy_path.yaml"), "--provider", "aurora_force",
        "--output", output, "--force"
      ]
      expect(run_cli(args, interactive: false).first).to eq(0)

      code, out, = run_cli(args, interactive: false)

      expect(code).to eq(0)
      expect(out).not_to include("Overwrite?")
    end
  end

  it "resolves Vector required requisites sequentially with explicit manual paths" do
    Dir.mktmpdir do |root|
      overrides = File.join(root, "vector.yml")
      answers = [
        "n", "100",
        "n", "m", "operation.payout_requisite.iban",
        "n", "m", "operation.payout_requisite.tax_id"
      ].join("\n") + "\n"
      code, out, = run_cli([
        "--spec", fixture("06_vector_bank_unknown_requisites.yaml"), "--provider", "vector_bank",
        "--output", File.join(root, "output"), "--overrides", overrides
      ], answers: answers)

      expect(code).to eq(0)
      expect(out).to include("beneficiary.iban", "beneficiary.tax_id", "Manual path is outside")
      data = YAML.safe_load_file(overrides)
      expect(data.dig("fields", "operation.payout_requisite.iban", "provider_path")).to eq("beneficiary.iban")
      expect(data.dig("fields", "operation.payout_requisite.tax_id", "provider_path")).to eq("beneficiary.tax_id")
      expect(File.read(File.join(root, "output", "vector_bank_service.rb"))).to include("disbursement_id")
    end
  end

  it "classifies missing callbacks and malformed YAML as fatal without opening review" do
    Dir.mktmpdir do |root|
      sable = run_cli([
        "--spec", fixture("05_sable_money_missing_callback.yaml"), "--provider", "sable",
        "--output", File.join(root, "sable"), "--non-interactive"
      ], interactive: false)
      broken = run_cli([
        "--spec", fixture("07_broken_yaml_intentional.yaml"), "--provider", "broken",
        "--output", File.join(root, "broken"), "--non-interactive"
      ], interactive: false)

      expect(sable.first).to eq(1)
      expect(sable.last).to include("Required callback operation was not found")
      expect(broken.first).to eq(1)
      expect(broken.last).to include("openapi_parse_error")
      expect(sable[1]).not_to include("REVIEW 1/")
      expect(Dir.exist?(File.join(root, "sable"))).to be(false)
    end
  end

  it "honors CLI values over config values" do
    Dir.mktmpdir do |root|
      config = File.join(root, "provider-compiler.yml")
      output = File.join(root, "cli-output")
      File.write(config, YAML.dump(
        "spec" => fixture("01_aurora_pay_happy_path.yaml"),
        "provider" => "from_config", "output" => File.join(root, "config-output")
      ))

      code, out, = run_cli([
        "--config", config, "--provider", "from_cli", "--output", output, "--non-interactive"
      ], interactive: false)

      expect(code).to eq(0)
      expect(out).to include("Provider: from_cli")
      expect(File.file?(File.join(output, "from_cli_service.rb"))).to be(true)
    end
  end

  it "supports spec and output paths with spaces and an underscore provider name" do
    Dir.mktmpdir do |root|
      spec_path = File.join(root, "input specs", "aurora api.yaml")
      output = File.join(root, "generated output")
      FileUtils.mkdir_p(File.dirname(spec_path))
      FileUtils.cp(fixture("01_aurora_pay_happy_path.yaml"), spec_path)

      code, = run_cli([
        "--spec", spec_path, "--provider", "aurora_pay", "--output", output, "--non-interactive"
      ], interactive: false)

      expect(code).to eq(0)
      expect(File.file?(File.join(output, "aurora_pay_service.rb"))).to be(true)
    end
  end

  it "accepts a JSON OpenAPI document through the complete CLI" do
    Dir.mktmpdir do |root|
      document = YAML.safe_load_file(fixture("01_aurora_pay_happy_path.yaml"), aliases: false)
      json_path = File.join(root, "aurora.json")
      File.write(json_path, JSON.pretty_generate(document))

      code, = run_cli([
        "--spec", json_path, "--provider", "aurora_json", "--output", File.join(root, "output"),
        "--non-interactive"
      ], interactive: false)

      expect(code).to eq(0)
    end
  end

  it "reports malformed and empty overrides without creating output" do
    Dir.mktmpdir do |root|
      malformed = File.join(root, "malformed.yml")
      empty = File.join(root, "empty.yml")
      File.write(malformed, "fields: [\n")
      File.write(empty, "")
      malformed_result = run_cli([
        "--spec", fixture("01_aurora_pay_happy_path.yaml"), "--provider", "aurora_bad_override",
        "--output", File.join(root, "bad-output"), "--overrides", malformed, "--non-interactive"
      ], interactive: false)
      empty_result = run_cli([
        "--spec", fixture("02_orbit_cash_renamed_but_clear.yaml"), "--provider", "orbit_empty_override",
        "--output", File.join(root, "empty-output"), "--overrides", empty, "--non-interactive"
      ], interactive: false)

      expect(malformed_result.first).to eq(1)
      expect(malformed_result.last).to include("override_parse_error")
      expect(empty_result.first).to eq(3)
      expect(Dir.exist?(File.join(root, "bad-output"))).to be(false)
      expect(Dir.exist?(File.join(root, "empty-output"))).to be(false)
    end
  end

  it "requires force when non-interactive output already exists" do
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      args = [
        "--spec", fixture("01_aurora_pay_happy_path.yaml"), "--provider", "aurora_noninteractive",
        "--output", output, "--non-interactive"
      ]
      expect(run_cli(args, interactive: false).first).to eq(0)

      code, _out, err = run_cli(args, interactive: false)

      expect(code).to eq(2)
      expect(err).to include("use --force")
    end
  end
end
