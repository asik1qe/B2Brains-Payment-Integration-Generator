# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Compiler do
  let(:loader) { double("loader") }
  let(:parser) { double("parser") }
  let(:mapper) { double("mapper") }
  let(:generator) { double("generator") }
  let(:verifier) { double("verifier") }
  let(:writer) { double("writer") }
  let(:configuration) do
    ProviderCompiler::Configuration.new(
      spec_path: "provider.yml",
      provider_name: "cli-provider",
      output_dir: "output",
      overrides_path: "overrides.yml"
    )
  end
  let(:document) { { "openapi" => "3.0.0" } }
  let(:provider_spec) { Object.new }
  let(:mapping_plan) { ProviderCompiler::Core::Mapping::MappingPlan.new(provider_name: "OpenAPI title") }
  let(:generated_integration) { Object.new }
  let(:verification_report) { { "syntax" => "passed" } }
  let(:written_files) { { "service.rb" => "C:/output/service.rb" } }

  subject(:compiler) do
    described_class.new(
      loader: loader, parser: parser, mapper: mapper, generator: generator,
      verifier: verifier, writer: writer
    )
  end

  def ok(value = nil, diagnostics: [])
    ProviderCompiler::Core::Result.success(value, diagnostics: diagnostics)
  end

  def failed(code, stage: :test)
    diagnostic = ProviderCompiler::Core::Diagnostic.new(
      severity: :error, code: code, message: code.to_s, stage: stage, state: :unresolved
    )
    ProviderCompiler::Core::Result.failure(nil, diagnostics: [diagnostic])
  end

  def warning(code, stage: :test)
    ProviderCompiler::Core::Diagnostic.new(
      severity: :warning, code: code, message: code.to_s, stage: stage, state: :needs_review
    )
  end

  def stub_success_pipeline
    allow(loader).to receive(:call).and_return(ok(document))
    allow(parser).to receive(:call).and_return(ok(provider_spec))
    allow(mapper).to receive(:call).and_return(ok(mapping_plan))
    allow(generator).to receive(:call).and_return(ok(generated_integration))
    allow(verifier).to receive(:call).and_return(ok(verification_report))
    allow(writer).to receive(:write).and_return(ok(written_files))
  end

  it "runs all six stages in strict order and returns all artifacts" do
    expect(loader).to receive(:call).with("provider.yml").ordered.and_return(ok(document))
    expect(parser).to receive(:call).with(document).ordered.and_return(ok(provider_spec))
    expect(mapper).to receive(:call).with(provider_spec, overrides: "overrides.yml").ordered.and_return(ok(mapping_plan))
    expect(generator).to receive(:call).with(
      mapping_plan: satisfy { |plan| plan.provider_name == "cli-provider" },
      provider_spec: provider_spec
    ).ordered.and_return(ok(generated_integration))
    expect(verifier).to receive(:call).ordered.and_return(ok(verification_report))
    expect(writer).to receive(:write).with(generated_integration, output_dir: "output").ordered.and_return(ok(written_files))

    result = compiler.call(configuration)

    expect(result).to be_success
    expect(result.value).to include(
      "provider_spec" => provider_spec,
      "generated_integration" => generated_integration,
      "verification" => verification_report,
      "written_files" => written_files
    )
    expect(result.value["mapping_plan"].provider_name).to eq("cli-provider")
  end

  it "stops after Loader failure" do
    allow(loader).to receive(:call).and_return(failed(:load_failed))
    allow(parser).to receive(:call)

    expect(compiler.call(configuration)).to be_failure
    expect(parser).not_to have_received(:call)
  end

  it "stops after Parser failure" do
    allow(loader).to receive(:call).and_return(ok(document))
    allow(parser).to receive(:call).and_return(failed(:parse_failed))
    allow(mapper).to receive(:call)

    expect(compiler.call(configuration)).to be_failure
    expect(mapper).not_to have_received(:call)
  end

  it "stops after Mapping failure" do
    allow(loader).to receive(:call).and_return(ok(document))
    allow(parser).to receive(:call).and_return(ok(provider_spec))
    allow(mapper).to receive(:call).and_return(failed(:mapping_failed))
    allow(generator).to receive(:call)

    expect(compiler.call(configuration)).to be_failure
    expect(generator).not_to have_received(:call)
  end

  it "stops after Generation failure" do
    stub_success_pipeline
    allow(generator).to receive(:call).and_return(failed(:generation_failed))

    expect(compiler.call(configuration)).to be_failure
    expect(verifier).not_to have_received(:call)
    expect(writer).not_to have_received(:write)
  end

  it "does not write after Verification failure" do
    stub_success_pipeline
    allow(verifier).to receive(:call).and_return(failed(:verification_failed))

    expect(compiler.call(configuration)).to be_failure
    expect(writer).not_to have_received(:write)
  end

  it "returns OutputWriter failure" do
    stub_success_pipeline
    allow(writer).to receive(:write).and_return(failed(:write_failed))

    result = compiler.call(configuration)

    expect(result).to be_failure
    expect(result.diagnostics.last.code).to eq("write_failed")
  end

  it "keeps stage warnings in order without duplicating carried diagnostics" do
    one = warning(:loader_warning, stage: :openapi)
    two = warning(:parser_warning, stage: :openapi)
    three = warning(:mapping_warning, stage: :mapping)
    four = warning(:generation_warning, stage: :generation)
    five = warning(:verification_warning, stage: :verification)
    allow(loader).to receive(:call).and_return(ok(document, diagnostics: [one]))
    allow(parser).to receive(:call).and_return(ok(provider_spec, diagnostics: [two]))
    allow(mapper).to receive(:call).and_return(ok(mapping_plan, diagnostics: [three]))
    allow(generator).to receive(:call).and_return(ok(generated_integration, diagnostics: [three, four]))
    allow(verifier).to receive(:call).and_return(ok(verification_report, diagnostics: [five]))
    allow(writer).to receive(:write).and_return(ok(written_files))

    result = compiler.call(configuration)

    expect(result).to be_success
    expect(result.diagnostics.map(&:code)).to eq(%w[loader_warning parser_warning mapping_warning generation_warning verification_warning])
  end

  it "rejects an invalid programming API argument" do
    expect { compiler.call(Object.new) }.to raise_error(ProviderCompiler::ConfigurationError)
  end
end
