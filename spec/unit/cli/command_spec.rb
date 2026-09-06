# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe ProviderCompiler::CLI::Command do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:presenter) { ProviderCompiler::CLI::Presenter.new(out: out, err: err) }

  def success_result
    ProviderCompiler::Core::Result.success({ "written_files" => {}, "verification" => {} })
  end

  def failure_result
    diagnostic = ProviderCompiler::Core::Diagnostic.new(
      severity: :error, code: :pipeline_failed, message: "Pipeline failed", state: :unresolved
    )
    ProviderCompiler::Core::Result.failure(nil, diagnostics: [diagnostic])
  end

  it "returns 0 for success" do
    compiler = double("compiler", call: success_result)
    command = described_class.new(compiler: compiler, presenter: presenter)

    expect(command.run(%w[--spec api.yml --provider orbit])).to eq(0)
    expect(out.string).to include("Status: SUCCESS")
  end

  it "returns 1 for pipeline failure" do
    compiler = double("compiler", call: failure_result)
    command = described_class.new(compiler: compiler, presenter: presenter)

    expect(command.run(%w[--spec api.yml --provider orbit])).to eq(1)
    expect(err.string).to include("Status: FAILED", "pipeline_failed")
  end

  it "returns 2 for invalid CLI arguments without a stack trace" do
    compiler = double("compiler")
    allow(compiler).to receive(:call)
    command = described_class.new(compiler: compiler, presenter: presenter)

    expect(command.run(%w[--provider orbit])).to eq(2)
    expect(err.string).to include("Missing required option: --spec")
    expect(err.string).not_to include("from ", ".rb:")
    expect(compiler).not_to have_received(:call)
  end

  it "returns 0 for help without invoking Compiler" do
    compiler = double("compiler")
    allow(compiler).to receive(:call)
    command = described_class.new(compiler: compiler, presenter: presenter)

    expect(command.run(["--help"])).to eq(0)
    expect(out.string).to include("Usage:", "Examples:")
    expect(compiler).not_to have_received(:call)
  end

  it "returns 1 for an unexpected exception without a stack trace" do
    compiler = double("compiler")
    allow(compiler).to receive(:call).and_raise("unexpected")
    command = described_class.new(compiler: compiler, presenter: presenter)

    expect(command.run(%w[--spec api.yml --provider orbit])).to eq(1)
    expect(err.string).to include("Internal error: unexpected")
    expect(err.string).not_to include("from ", ".rb:")
  end

  it "runs the real NovaPay pipeline and writes exactly three files" do
    spec_path = SpecPaths.fixture("official", "novapay_provider_api.yaml")
    overrides = SpecPaths.fixture("overrides", "novapay_overrides.yml")
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      command = described_class.new(presenter: presenter)

      exit_code = command.run([
        "--spec", spec_path, "--provider", "novapay", "--overrides", overrides, "--output", output
      ])

      expect(exit_code).to eq(0)
      expect(Dir.children(output)).to contain_exactly("novapay_service.rb", "INTEGRATION.md", "fixtures.json")
      expect(File.binread(File.join(output, "novapay_service.rb"))).to include("class Provider::NovapayService < Provider::BaseService")
      expect(out.string).to include("Status: SUCCESS", "syntax: passed", "webhook_signature_runtime_unavailable")
    end
  end
end
