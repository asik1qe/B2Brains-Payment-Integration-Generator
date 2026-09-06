# frozen_string_literal: true

require_relative "configuration"
require_relative "core/result"
require_relative "core/mapping/mapping_plan"
require_relative "openapi/loader"
require_relative "openapi/parser"
require_relative "mapping/mapper"
require_relative "generation/service_generator"
require_relative "generation/output_writer"
require_relative "verification/verifier"

module ProviderCompiler
  class Compiler
    def initialize(
      loader: OpenAPI::Loader.new,
      parser: OpenAPI::Parser.new,
      mapper: Mapping::Mapper.new,
      generator: Generation::ServiceGenerator.new,
      verifier: Verification::Verifier.new,
      writer: Generation::OutputWriter.new
    )
      @loader = loader
      @parser = parser
      @mapper = mapper
      @generator = generator
      @verifier = verifier
      @writer = writer
    end

    def call(configuration)
      unless configuration.is_a?(ProviderCompiler::Configuration)
        raise ProviderCompiler::ConfigurationError, "configuration must be a ProviderCompiler::Configuration"
      end

      parsed = parse(configuration)
      return parsed if parsed.failure?

      mapped = map(parsed.value, configuration)
      return failed(parsed.diagnostics + mapped.diagnostics, mapped.value) if mapped.failure?

      finish(
        configuration,
        provider_spec: parsed.value,
        mapping_plan: mapped.value,
        diagnostics: parsed.diagnostics + mapped.diagnostics
      )
    end

    def parse(configuration)
      validate_configuration!(configuration)
      diagnostics = []
      loaded = @loader.call(configuration.spec_path)
      append_diagnostics(diagnostics, loaded)
      return failed(diagnostics) if loaded.failure?

      parsed = @parser.call(loaded.value)
      append_diagnostics(diagnostics, parsed)
      return failed(diagnostics) if parsed.failure?

      ProviderCompiler::Core::Result.success(parsed.value, diagnostics: diagnostics)
    end

    def map(provider_spec, configuration)
      validate_configuration!(configuration)
      mapped = @mapper.call(provider_spec, overrides: configuration.overrides_path)
      plan = mapped.value && with_provider_name(mapped.value, configuration.provider_name)
      if mapped.failure?
        ProviderCompiler::Core::Result.failure(plan, diagnostics: mapped.diagnostics)
      else
        ProviderCompiler::Core::Result.success(plan, diagnostics: mapped.diagnostics)
      end
    end

    def finish(configuration, provider_spec:, mapping_plan:, diagnostics: [])
      validate_configuration!(configuration)
      diagnostics = diagnostics.dup
      generated = @generator.call(mapping_plan: mapping_plan, provider_spec: provider_spec)
      append_diagnostics(diagnostics, generated)
      return failed(diagnostics) if generated.failure?
      generated_integration = generated.value

      verified = @verifier.call(
        generated_integration: generated_integration,
        mapping_plan: mapping_plan,
        provider_spec: provider_spec
      )
      append_diagnostics(diagnostics, verified)
      return failed(diagnostics) if verified.failure?

      written = @writer.write(generated_integration, output_dir: configuration.output_dir)
      append_diagnostics(diagnostics, written)
      return failed(diagnostics) if written.failure?

      value = {
        "provider_spec" => provider_spec,
        "mapping_plan" => mapping_plan,
        "generated_integration" => generated_integration,
        "verification" => verified.value,
        "written_files" => written.value
      }
      ProviderCompiler::Core::Result.success(value, diagnostics: diagnostics)
    end

    private

    def validate_configuration!(configuration)
      return if configuration.is_a?(ProviderCompiler::Configuration)

      raise ProviderCompiler::ConfigurationError, "configuration must be a ProviderCompiler::Configuration"
    end

    def with_provider_name(plan, provider_name)
      ProviderCompiler::Core::Mapping::MappingPlan.new(
        provider_name: provider_name,
        operations: plan.operations,
        fields: plan.fields,
        statuses: plan.statuses,
        errors: plan.errors,
        security: plan.security,
        webhook: plan.webhook,
        conditions: plan.conditions,
        diagnostics: plan.diagnostics,
        metadata: plan.metadata
      )
    end

    def append_diagnostics(collection, stage_result)
      stage_result.diagnostics.each do |diagnostic|
        duplicate = collection.any? { |existing| diagnostic_key(existing) == diagnostic_key(diagnostic) }
        collection << diagnostic unless duplicate
      end
    end

    def diagnostic_key(diagnostic)
      [diagnostic.stage, diagnostic.severity, diagnostic.code, diagnostic.state, diagnostic.location, diagnostic.message]
    end

    def failed(diagnostics, value = nil)
      ProviderCompiler::Core::Result.failure(value, diagnostics: diagnostics)
    end
  end
end
