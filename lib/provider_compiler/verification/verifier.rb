# frozen_string_literal: true

require_relative "../core/result"
require_relative "syntax_checker"
require_relative "fixture_validator"
require_relative "contract_checker"
require_relative "scenario_runner"

module ProviderCompiler
  module Verification
    class Verifier
      def initialize(
        syntax_checker: SyntaxChecker.new,
        fixture_validator: FixtureValidator.new,
        contract_checker: ContractChecker.new,
        scenario_runner: ScenarioRunner.new
      )
        @syntax_checker = syntax_checker
        @fixture_validator = fixture_validator
        @contract_checker = contract_checker
        @scenario_runner = scenario_runner
      end

      def call(generated_integration:, mapping_plan:, provider_spec: nil)
        report = {
          "syntax" => "skipped",
          "fixtures" => "skipped",
          "contract" => "skipped",
          "scenarios" => skipped_scenarios
        }
        diagnostics = []

        syntax = @syntax_checker.call(
          generated_integration.service_code,
          filename: generated_integration.service_filename || "(generated)"
        )
        report["syntax"] = status(syntax)
        diagnostics.concat(syntax.diagnostics)
        return result(report, diagnostics) if syntax.failure?

        fixtures = @fixture_validator.call(generated_integration, mapping_plan: mapping_plan)
        report["fixtures"] = status(fixtures)
        diagnostics.concat(fixtures.diagnostics)

        contract = @contract_checker.call(generated_integration)
        report["contract"] = status(contract)
        diagnostics.concat(contract.diagnostics)

        if fixtures.success? && contract.success?
          scenarios = @scenario_runner.call(
            generated_integration: generated_integration,
            mapping_plan: mapping_plan,
            provider_spec: provider_spec
          )
          report["scenarios"] = scenarios.value
          diagnostics.concat(scenarios.diagnostics)
        end

        result(report, diagnostics)
      end

      private

      def skipped_scenarios
        ScenarioRunner::SCENARIOS.to_h { |name| [name, "skipped"] }
      end

      def status(check)
        check.success? ? "passed" : "failed"
      end

      def result(report, diagnostics)
        if diagnostics.any?(&:blocking?)
          ProviderCompiler::Core::Result.failure(report, diagnostics: diagnostics)
        else
          ProviderCompiler::Core::Result.success(report, diagnostics: diagnostics)
        end
      end
    end
  end
end
