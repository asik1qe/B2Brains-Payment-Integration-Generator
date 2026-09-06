# frozen_string_literal: true

require "json"
require_relative "service_renderer"
require_relative "documentation_generator"
require_relative "fixtures_generator"
require_relative "../core/diagnostic"
require_relative "../core/result"
require_relative "../core/generated_integration"
require_relative "../core/mapping/mapping_plan"

module ProviderCompiler
  module Generation
    class ServiceGenerator
      def initialize(
        service_renderer: ServiceRenderer.new,
        documentation_generator: DocumentationGenerator.new,
        fixtures_generator: FixturesGenerator.new
      )
        @service_renderer = service_renderer
        @documentation_generator = documentation_generator
        @fixtures_generator = fixtures_generator
      end

      def call(mapping_plan:, provider_spec: nil)
        diagnostics = mapping_plan.diagnostics.dup
        unless mapping_plan.resolved?
          diagnostics << diagnostic(
            :mapping_plan_unresolved,
            "MappingPlan contains blocking diagnostics",
            :unresolved
          )
          return ProviderCompiler::Core::Result.failure(nil, diagnostics: deduplicate(diagnostics))
        end

        unless present?(mapping_plan.provider_name)
          diagnostics << diagnostic(:provider_name_missing, "Provider name is required", :unresolved)
          return ProviderCompiler::Core::Result.failure(nil, diagnostics: deduplicate(diagnostics))
        end

        stem = provider_stem(mapping_plan.provider_name)
        class_name = class_name(stem)
        service_filename = "#{stem}_service.rb"
        service_code = @service_renderer.render(mapping_plan: mapping_plan, class_name: class_name)
        diagnostics.concat(@service_renderer.respond_to?(:diagnostics) ? @service_renderer.diagnostics : [])
        diagnostics = deduplicate(diagnostics)
        return ProviderCompiler::Core::Result.failure(nil, diagnostics: diagnostics) if diagnostics.any?(&:blocking?)

        documented_plan = copy_plan(mapping_plan, diagnostics)
        integration_markdown = @documentation_generator.generate(
          mapping_plan: documented_plan,
          provider_spec: provider_spec,
          service_filename: service_filename
        )
        fixtures_hash = @fixtures_generator.generate(mapping_plan: mapping_plan, provider_spec: provider_spec)
        fixtures_json = JSON.pretty_generate(fixtures_hash) + "\n"
        generated = ProviderCompiler::Core::GeneratedIntegration.new(
          service_code: service_code,
          integration_markdown: integration_markdown,
          fixtures_json: fixtures_json,
          service_filename: service_filename,
          provider_name: mapping_plan.provider_name,
          metadata: {
            "class_name" => class_name,
            "qualified_class_name" => "Provider::#{class_name}"
          }
        )
        ProviderCompiler::Core::Result.success(generated, diagnostics: diagnostics)
      rescue StandardError => error
        item = diagnostic(:generation_error, "Unable to generate integration: #{error.message}", :unresolved)
        ProviderCompiler::Core::Result.failure(nil, diagnostics: [item])
      end

      private

      def provider_stem(name)
        value = name.to_s
                    .gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
                    .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
                    .gsub(/[^a-zA-Z0-9]+/, "_")
                    .gsub(/\A_+|_+\z/, "")
                    .downcase
        value = "provider" if value.empty?
        value = "provider_#{value}" unless value.match?(/\A[a-z]/)
        value
      end

      def class_name(stem)
        stem.split("_").map(&:capitalize).join + "Service"
      end

      def copy_plan(plan, diagnostics)
        ProviderCompiler::Core::Mapping::MappingPlan.new(
          provider_name: plan.provider_name,
          operations: plan.operations,
          fields: plan.fields,
          statuses: plan.statuses,
          errors: plan.errors,
          security: plan.security,
          webhook: plan.webhook,
          conditions: plan.conditions,
          diagnostics: diagnostics,
          metadata: plan.metadata
        )
      end

      def diagnostic(code, message, state)
        ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :generation,
          state: state
        )
      end

      def deduplicate(diagnostics)
        diagnostics.uniq do |item|
          if item.respond_to?(:code)
            [item.code, item.severity, item.state, item.location, item.message]
          else
            item
          end
        end
      end

      def present?(value)
        !value.nil? && (!value.respond_to?(:empty?) || !value.empty?)
      end
    end
  end
end
