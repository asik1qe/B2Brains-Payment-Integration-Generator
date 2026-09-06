# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "yaml"

RSpec.describe ProviderCompiler::CLI::ReviewSession do
  def configuration(overrides_path: nil)
    ProviderCompiler::Configuration.new(
      spec_path: SpecPaths.fixture("official", "novapay_provider_api.yaml"),
      provider_name: "review_unit",
      output_dir: "output",
      overrides_path: overrides_path
    )
  end

  def diagnostic(code:, severity: :warning, state: :needs_review, location: nil)
    ProviderCompiler::Core::Diagnostic.new(
      severity: severity,
      code: code,
      message: code,
      stage: :mapping,
      state: state,
      location: location
    )
  end

  def security_review_result
    alternatives = [
      {
        "scheme_key" => "BearerAuth",
        "type" => "bearer",
        "credential_path" => "access_token",
        "prefix" => "Bearer"
      },
      {
        "scheme_key" => "ApiKeyAuth",
        "type" => "apiKey",
        "location" => "header",
        "name" => "X-API-Key",
        "credential_path" => "api_key"
      }
    ]
    security = ProviderCompiler::Core::Mapping::SecurityMapping.new(
      type: "bearer",
      scheme_key: "BearerAuth",
      decision: :needs_review,
      metadata: { "alternatives" => alternatives }
    )
    plan = ProviderCompiler::Core::Mapping::MappingPlan.new(security: security)
    review = diagnostic(code: "security_mapping_needs_review", location: "security")
    ProviderCompiler::Core::Result.success(plan, diagnostics: [review])
  end

  it "returns resolved immediately when there are no reviewable diagnostics" do
    compiler = instance_double(ProviderCompiler::Compiler)
    result = ProviderCompiler::Core::Result.success(ProviderCompiler::Core::Mapping::MappingPlan.new)
    session = described_class.new(compiler: compiler, input: StringIO.new, out: StringIO.new)

    resolved = session.run(
      provider_spec: Object.new,
      mapping_result: result,
      configuration: configuration,
      overrides_path: "unused.yml"
    )

    expect(resolved.status).to eq(:resolved)
    expect(resolved.mapping_result).to equal(result)
  end

  it "returns fatal without prompting when a non-reviewable blocking diagnostic exists" do
    compiler = instance_double(ProviderCompiler::Compiler)
    fatal = diagnostic(code: "callback_operation_unresolved", severity: :error, state: :unresolved)
    result = ProviderCompiler::Core::Result.failure(nil, diagnostics: [fatal])
    output = StringIO.new
    session = described_class.new(compiler: compiler, input: StringIO.new("1\n"), out: output)

    resolved = session.run(
      provider_spec: Object.new,
      mapping_result: result,
      configuration: configuration,
      overrides_path: "unused.yml"
    )

    expect(resolved.status).to eq(:fatal)
    expect(output.string).to be_empty
  end

  it "allows a user to abort a review without writing an override" do
    Dir.mktmpdir do |root|
      path = File.join(root, "review.yml")
      compiler = instance_double(ProviderCompiler::Compiler)
      session = described_class.new(compiler: compiler, input: StringIO.new("q\n"), out: StringIO.new)

      resolved = session.run(
        provider_spec: Object.new,
        mapping_result: security_review_result,
        configuration: configuration,
        overrides_path: path
      )

      expect(resolved.status).to eq(:aborted)
      expect(File.exist?(path)).to be(false)
    end
  end

  it "persists one explicit security choice, remaps, and stops asking after resolution" do
    Dir.mktmpdir do |root|
      path = File.join(root, "review.yml")
      compiler = instance_double(ProviderCompiler::Compiler)
      resolved_mapping = ProviderCompiler::Core::Result.success(
        ProviderCompiler::Core::Mapping::MappingPlan.new(
          security: ProviderCompiler::Core::Mapping::SecurityMapping.new(
            type: "bearer", scheme_key: "BearerAuth", decision: :manual
          )
        )
      )
      expect(compiler).to receive(:map).once.and_return(resolved_mapping)
      output = StringIO.new
      session = described_class.new(compiler: compiler, input: StringIO.new("1\n"), out: output)

      resolved = session.run(
        provider_spec: Object.new,
        mapping_result: security_review_result,
        configuration: configuration,
        overrides_path: path
      )

      expect(resolved.status).to eq(:resolved)
      saved = YAML.safe_load_file(path, aliases: false)
      expect(saved.dig("security", "scheme_key")).to eq("BearerAuth")
      expect(output.string).to include("security -> BearerAuth")
    end
  end
end
