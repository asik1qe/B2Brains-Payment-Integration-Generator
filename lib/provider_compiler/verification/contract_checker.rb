# frozen_string_literal: true

require_relative "../core/diagnostic"
require_relative "../core/result"
require_relative "../core/space_payments_contract"
require_relative "runtime"

module ProviderCompiler
  module Verification
    class ContractChecker
      def initialize(runtime: Runtime.new)
        @runtime = runtime
      end

      def call(generated_integration)
        loaded = @runtime.load(generated_integration)
        return wrong_base_result(loaded) if wrong_base_class?(loaded)
        return loaded if loaded.failure?

        context = loaded.value
        klass = context.fetch("service_class")
        base = context.fetch("fake_base_service")
        diagnostics = []
        diagnostics << diagnostic(:generated_service_wrong_base_class, "Generated service has the wrong base class") unless klass < base
        expected_class = generated_integration.metadata["class_name"] || generated_integration.metadata[:class_name]
        if expected_class
          provider = context.fetch("provider")
          namespaced = provider.const_defined?(expected_class.to_sym, false) &&
            provider.const_get(expected_class.to_sym, false).equal?(klass)
          diagnostics << diagnostic(
            :generated_service_wrong_namespace,
            "Generated service must be defined as Provider::#{expected_class}"
          ) unless namespaced
        end

        ProviderCompiler::Core::SpacePaymentsContract::REQUIRED_SERVICE_METHODS.each do |name|
          unless klass.public_method_defined?(name)
            diagnostics << diagnostic(
              :generated_service_missing_method,
              "Generated service is missing public method #{name}",
              name
            )
            next
          end

          method = klass.instance_method(name)
          parameters = method.parameters
          accepts_one = accepts_positional_arguments?(parameters, 1)
          accepts_request_method = !%w[check_conditions create_request].include?(name) ||
            accepts_positional_arguments?(parameters, 2)
          next if accepts_one && accepts_request_method

          expected = %w[check_conditions create_request].include?(name) ? "one or two positional arguments" : "one positional argument"
          diagnostics << diagnostic(
            :generated_service_invalid_method_signature,
            "Generated service method #{name} must accept #{expected}",
            name
          )
        end

        generated_integration.service_code.scan(/failure\(\s*:([a-z][a-z0-9_]*)/).flatten.uniq.each do |code|
          next if ProviderCompiler::Core::SpacePaymentsContract.failure_code?(code)

          diagnostics << diagnostic(
            :generated_service_unsupported_failure_code,
            "Generated service uses unsupported platform failure code #{code}"
          )
        end

        report = { "valid" => diagnostics.empty?, "service_class" => klass.name }
        return ProviderCompiler::Core::Result.success(report) if diagnostics.empty?

        ProviderCompiler::Core::Result.failure(report, diagnostics: diagnostics)
      end

      private

      def accepts_positional_arguments?(parameters, count)
        required = parameters.count { |kind, _| kind == :req }
        optional = parameters.count { |kind, _| kind == :opt }
        rest = parameters.any? { |kind, _| kind == :rest }
        required_keywords = parameters.any? { |kind, _| kind == :keyreq }
        return false if required_keywords || required > count

        rest || required + optional >= count
      end

      def wrong_base_class?(loaded)
        return false unless loaded.failure?
        return false unless loaded.diagnostics.any? { |item| item.code == "generated_service_class_not_found" }

        loaded.value.is_a?(Hash) && loaded.value.fetch("candidate_classes", []).size == 1
      end

      def wrong_base_result(loaded)
        diagnostic = diagnostic(
          :generated_service_wrong_base_class,
          "Generated service does not inherit from Provider::BaseService"
        )
        ProviderCompiler::Core::Result.failure(
          { "valid" => false, "service_class" => loaded.value["candidate_classes"].first.name },
          diagnostics: [diagnostic]
        )
      end

      def diagnostic(code, message, method_name = nil)
        metadata = {}
        metadata["method_name"] = method_name if method_name
        ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :verification,
          state: :unresolved,
          metadata: metadata
        )
      end
    end
  end
end
