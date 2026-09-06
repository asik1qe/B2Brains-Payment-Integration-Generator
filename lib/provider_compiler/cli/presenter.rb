# frozen_string_literal: true

module ProviderCompiler
  module CLI
    class Presenter
      STAGE_NUMBERS = { "OpenAPI" => 1, "Mapping" => 2, "Review" => 3, "Generation" => 4, "Verification" => 5 }.freeze
      attr_reader :out, :err

      def initialize(out: $stdout, err: $stderr)
        @out = out
        @err = err
      end

      def present(result, configuration: nil)
        if result.success?
          success(result, configuration: configuration)
        else
          failure(result)
        end
      end

      def success(result, configuration: nil)
        lines = ["Provider Compiler", ""]
        provider = configuration&.provider_name || result.value["mapping_plan"]&.provider_name
        lines << "Provider: #{sanitize(provider)}" if provider
        lines.concat(["Status: SUCCESS", "", "Generated:"])
        result.value.fetch("written_files", {}).each_value { |path| lines << "  #{sanitize(path)}" }
        lines.concat(["", "Verification:"])
        lines.concat(verification_lines(result.value["verification"] || {}))
        append_diagnostics(lines, "Warnings", result.warnings)
        @out.puts(lines.join("\n"))
      end

      alias present_success success

      def failure(result)
        lines = ["Provider Compiler", "", "Status: FAILED"]
        errors = result.errors
        errors = result.blocking_diagnostics if errors.empty?
        append_diagnostics(lines, "Errors", errors)
        append_diagnostics(lines, "Warnings", result.warnings)
        @err.puts(lines.join("\n"))
      end

      alias present_failure failure

      def help(text)
        @out.puts(text)
      end

      def usage_error(message, help_text: nil)
        @err.puts("Provider Compiler\n\nUsage error: #{sanitize(message)}")
        @err.puts("\n#{help_text}") if help_text
      end

      def internal_error(message)
        @err.puts("Provider Compiler\n\nStatus: FAILED\n\nInternal error: #{sanitize(message)}")
      end

      def start(configuration, debug: false)
        @out.puts("Provider Compiler\n")
        @out.puts("Provider: #{sanitize(configuration.provider_name)}")
        @out.puts("Spec: #{sanitize(configuration.spec_path)}")
        @out.puts("Output: #{sanitize(configuration.output_dir)}") if debug
      end

      def stage(name, status, detail = nil)
        prefix = STAGE_NUMBERS[name] ? "[#{STAGE_NUMBERS[name]}/5] " : ""
        line = "#{prefix}#{name.ljust(13)} #{status}"
        line += " (#{sanitize(detail)})" if detail
        @out.puts(line)
      end

      def overrides(path)
        @out.puts("Overrides:\n  #{sanitize(path)}")
      end

      def needs_review(diagnostics)
        lines = ["", "Status: NEEDS REVIEW", "", "Review required:"]
        diagnostics.each do |diagnostic|
          lines << "  - #{diagnostic.code}: #{sanitize(diagnostic.message)} [#{sanitize(diagnostic.location)}]"
        end
        @out.puts(lines.join("\n"))
      end

      def pipeline_failure(result)
        @err.puts("\nStatus: FAILED")
        diagnostics = result.respond_to?(:errors) ? result.errors : []
        diagnostics = result.blocking_diagnostics if diagnostics.empty? && result.respond_to?(:blocking_diagnostics)
        diagnostics.each do |diagnostic|
          @err.puts("  - #{diagnostic.code}: #{sanitize(diagnostic.message)}")
        end
      end

      def openapi_failure(result, path)
        @err.puts("\nStatus: FAILED\n\nOpenAPI could not be parsed.\n\nFile:\n  #{sanitize(path)}")
        result.blocking_diagnostics.each do |diagnostic|
          @err.puts("\nParser:\n  #{diagnostic.code}: #{sanitize(diagnostic.message)}")
        end
        @err.puts("\nGeneration was not started.")
      end

      def mapping_failure(result, provider_spec)
        callback_missing = result.blocking_diagnostics.any? do |diagnostic|
          diagnostic.code == "operation_mapping_unresolved" && diagnostic.location.to_s == "process_callback"
        end
        return pipeline_failure(result) unless callback_missing

        lines = [
          "", "Status: FAILED", "", "Required callback operation was not found.", "",
          "Required platform method:", "  process_callback", "", "OpenAPI operations checked:"
        ]
        provider_spec.operations.each { |operation| lines << "  #{operation.http_method} #{operation.path}" }
        lines.concat([
          "", "No callback/webhook candidate exists.", "",
          "This cannot be fixed by selecting another detected mapping.",
          "Add or choose a specification that contains the provider callback API.", "",
          "Generation was not started."
        ])
        @err.puts(lines.join("\n"))
      end

      def pipeline_success(result)
        @out.puts("\nStatus: SUCCESS\n\nGenerated:")
        result.value.fetch("written_files", {}).each_value { |path| @out.puts("  #{sanitize(path)}") }
        @out.puts("\nVerification:")
        @out.puts(verification_lines(result.value["verification"] || {}).join("\n"))
        warnings = result.respond_to?(:warnings) ? result.warnings : []
        unless warnings.empty?
          lines = []
          append_diagnostics(lines, "Warnings", warnings)
          @out.puts(lines.join("\n"))
        end
      end

      def aborted(message = "Aborted by user.")
        @err.puts("\nStatus: FAILED\n#{sanitize(message)}")
      end

      def debug(message)
        @out.puts("[DEBUG] #{sanitize(message)}")
      end

      def warnings(diagnostics)
        return if diagnostics.empty?

        @out.puts("\nWarnings: #{diagnostics.length}")
        diagnostics.each { |diagnostic| @out.puts("  - #{sanitize(diagnostic.message)}") }
      end

      private

      def verification_lines(report)
        lines = %w[syntax fixtures contract].map do |name|
          "  #{name}: #{report.fetch(name, "skipped")}"
        end
        scenarios = report["scenarios"] || {}
        failed = scenarios.select { |_name, status| status == "failed" }.keys
        skipped = scenarios.select { |_name, status| status == "skipped" }.keys
        lines << "  scenarios: #{failed.empty? ? "passed" : "failed"}"
        lines << "  failed: #{failed.join(", ")}" unless failed.empty?
        lines << "  skipped: #{skipped.join(", ")}" unless skipped.empty?
        lines
      end

      def append_diagnostics(lines, heading, diagnostics)
        return if diagnostics.empty?

        lines.concat(["", "#{heading}:"])
        diagnostics.each do |diagnostic|
          location = diagnostic.location
          suffix = location.nil? ? "" : " [#{sanitize(location)}]"
          lines << "  - #{diagnostic.severity} #{diagnostic.code}: #{sanitize(diagnostic.message)}#{suffix}"
        end
      end

      def sanitize(value)
        value.to_s.gsub(
          /(api[_ -]?key|authorization|token|password|secret)(\s*[:=]\s*)(\S+)/i,
          '\\1\\2[REDACTED]'
        )
      end
    end
  end
end
