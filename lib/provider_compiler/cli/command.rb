# frozen_string_literal: true

require "optparse"
require_relative "../compiler"
require_relative "../errors"
require_relative "options"
require_relative "presenter"
require_relative "review_classifier"
require_relative "review_session"

module ProviderCompiler
  module CLI
    class Command
      SUCCESS = 0
      FAILURE = 1
      USAGE_ERROR = 2
      NEEDS_REVIEW = 3

      def initialize(
        options: Options.new,
        compiler: ProviderCompiler::Compiler.new,
        presenter: Presenter.new,
        input: $stdin,
        interactive: nil,
        cwd: Dir.pwd
      )
        @options = options
        @compiler = compiler
        @presenter = presenter
        @input = input
        @interactive = interactive
        @cwd = cwd
      end

      def run(argv)
        parsed_options = @options.parse(argv)
        if @options.help?
          @presenter.help(@options.help_text)
          return SUCCESS
        end

        values = ProviderCompiler::Configuration.resolve(parsed_options, cwd: @cwd)
        debug = values[:debug] == true
        non_interactive = values[:non_interactive] == true
        force = values[:force] == true
        return legacy_run(legacy_configuration(values)) unless @compiler.respond_to?(:parse) && @compiler.respond_to?(:map)

        interactive = interactive?(non_interactive)
        values = obtain_required_values(values, interactive: interactive)
        configuration = build_configuration(values)
        default_overrides = default_overrides_path(configuration.provider_name)
        if configuration.overrides_path.nil? && File.file?(absolute(default_overrides))
          configuration = configuration_with_overrides(configuration, default_overrides)
        end

        @presenter.start(configuration, debug: debug)
        @presenter.debug("configuration=#{configuration.to_h.inspect}") if debug
        @presenter.overrides(configuration.overrides_path) if configuration.overrides?
        @presenter.debug("loaded overrides=#{configuration.overrides_path}") if debug && configuration.overrides?

        parsed = @compiler.parse(configuration)
        if parsed.failure?
          @presenter.stage("OpenAPI", "FAILED")
          debug_diagnostics(parsed, debug)
          @presenter.openapi_failure(parsed, configuration.spec_path)
          return FAILURE
        end
        @presenter.stage("OpenAPI", "OK", "#{parsed.value.operations.length} operations")
        @presenter.debug("schemas=#{parsed.value.schemas.keys.sort.join(', ')}") if debug

        review_overrides_path = configuration.overrides_path || default_overrides
        mapping_configuration = if configuration.overrides_path && !File.file?(configuration.overrides_path)
                                  configuration_with_overrides(configuration, nil)
                                else
                                  configuration
                                end
        mapped = @compiler.map(parsed.value, mapping_configuration)
        debug_mapping(mapped, debug)
        classifier = ReviewClassifier.new
        debug_diagnostics(mapped, debug)
        fatals = classifier.fatal(mapped.diagnostics)
        unless fatals.empty?
          @presenter.stage("Mapping", "FAILED")
          @presenter.mapping_failure(mapped, parsed.value)
          return FAILURE
        end

        reviews = classifier.reviewable(mapped.diagnostics)
        unless reviews.empty?
          @presenter.stage("Mapping", "REVIEW", "#{reviews.length} issue(s)")
          unless interactive
            @presenter.needs_review(reviews)
            return NEEDS_REVIEW
          end

          session = ReviewSession.new(
            compiler: @compiler, input: @input, out: @presenter.out,
            classifier: classifier, debug: debug
          )
          reviewed = session.run(
            provider_spec: parsed.value,
            mapping_result: mapped,
            configuration: mapping_configuration,
            overrides_path: review_overrides_path
          )
          if reviewed.status == :aborted
            @presenter.aborted("Aborted by user.\nNo generated files were written.")
            return FAILURE
          elsif reviewed.status == :fatal
            @presenter.pipeline_failure(reviewed.mapping_result)
            return FAILURE
          end
          mapped = reviewed.mapping_result
          configuration = reviewed.configuration
          @presenter.stage("Mapping", "OK")
          @presenter.stage("Review", "resolved")
        else
          @presenter.stage("Mapping", "OK")
          @presenter.stage("Review", "not required")
        end

        @presenter.warnings(mapped.diagnostics.reject(&:blocking?))
        overwrite = allow_overwrite?(configuration.output_dir, force: force, interactive: interactive)
        return overwrite unless overwrite == true

        @presenter.stage("Generation", "running") if debug
        result = @compiler.finish(
          configuration,
          provider_spec: parsed.value,
          mapping_plan: mapped.value,
          diagnostics: parsed.diagnostics + mapped.diagnostics
        )
        if result.failure?
          @presenter.pipeline_failure(result)
          return FAILURE
        end

        @presenter.stage("Generation", "OK")
        @presenter.stage("Verification", "OK")
        @presenter.debug("verification=#{result.value['verification'].inspect}") if debug
        @presenter.pipeline_success(result)
        SUCCESS
      rescue ProviderCompiler::ConfigurationError, ProviderCompiler::CliError, OptionParser::ParseError => error
        @presenter.usage_error(error.message, help_text: @options.help_text)
        USAGE_ERROR
      rescue ProviderCompiler::UserAbort
        @presenter.aborted("Aborted by user.\nNo generated files were written.")
        FAILURE
      rescue StandardError => error
        @presenter.internal_error(error.message)
        @presenter.err.puts(error.full_message) if defined?(debug) && debug
        FAILURE
      end

      private

      def obtain_required_values(values, interactive:)
        result = values.dup
        unless present?(result[:spec_path]) && File.file?(absolute(result[:spec_path]))
          raise ProviderCompiler::CliError, "OpenAPI file is required or does not exist" unless interactive

          @presenter.out.puts("OpenAPI file not found:\n  #{result[:spec_path]}") if present?(result[:spec_path])
          result[:spec_path] = prompt_existing_file("OpenAPI file:")
        end
        unless present?(result[:provider_name])
          raise ProviderCompiler::CliError, "Provider name is required" unless interactive

          result[:provider_name] = prompt_nonempty("Provider name:")
          raise ProviderCompiler::UserAbort if result[:provider_name] == :abort
        end
        unless present?(result[:output_dir])
          if interactive
            result[:output_dir] = prompt("Output directory [./output]:", default: "./output")
          else
            result[:output_dir] = "./output"
          end
        end
        result
      end

      def build_configuration(values)
        ProviderCompiler::Configuration.new(
          spec_path: values[:spec_path],
          provider_name: values[:provider_name],
          output_dir: values[:output_dir],
          overrides_path: values[:overrides_path]
        )
      end

      def interactive?(non_interactive)
        return false if non_interactive
        return @interactive unless @interactive.nil?

        @input.respond_to?(:tty?) && @input.tty? && @presenter.out.respond_to?(:tty?) && @presenter.out.tty?
      end

      def prompt_existing_file(label)
        loop do
          value = prompt_nonempty(label)
          raise ProviderCompiler::UserAbort if value == :abort
          return value if File.file?(absolute(value))

          @presenter.out.puts("OpenAPI file not found. Try again, or enter q to abort.")
        end
      end

      def prompt_nonempty(label)
        loop do
          value = prompt(label)
          return :abort if value.nil? || value.casecmp?("q")
          return value unless value.empty?

          @presenter.out.puts("Value must not be blank.")
        end
      end

      def prompt(label, default: nil)
        @presenter.out.puts("\n#{label}")
        @presenter.out.print("> ")
        line = @input.gets
        return nil if line.nil?
        value = line.strip
        value.empty? ? default.to_s : value
      end

      def allow_overwrite?(output_dir, force:, interactive:)
        files = generated_files(output_dir)
        return true if files.empty? || force

        unless interactive
          @presenter.usage_error("Output already contains generated files; use --force")
          return USAGE_ERROR
        end

        @presenter.out.puts("\nOutput already contains generated files.\n\n#{files.map { |name| "  #{name}" }.join("\n")}")
        answer = prompt("Overwrite? [y/N]")
        return true if answer&.casecmp?("y")

        @presenter.aborted("Output was not overwritten.")
        FAILURE
      end

      def generated_files(output_dir)
        directory = absolute(output_dir)
        return [] unless Dir.exist?(directory)

        Dir.children(directory).select do |name|
          name == "fixtures.json" || name == "INTEGRATION.md" || name.end_with?("_service.rb")
        end
      end

      def legacy_run(configuration)
        result = @compiler.call(configuration)
        @presenter.present(result, configuration: configuration)
        result.success? ? SUCCESS : FAILURE
      end

      def legacy_configuration(values)
        raise ProviderCompiler::CliError, "Missing required option: --spec" unless present?(values[:spec_path])
        raise ProviderCompiler::CliError, "Missing required option: --provider" unless present?(values[:provider_name])

        ProviderCompiler::Configuration.new(
          spec_path: values[:spec_path], provider_name: values[:provider_name],
          output_dir: values[:output_dir] || "./output", overrides_path: values[:overrides_path]
        )
      end

      def configuration_with_overrides(configuration, path)
        ProviderCompiler::Configuration.new(**configuration.to_h.merge(overrides_path: path))
      end

      def default_overrides_path(provider_name)
        ProviderCompiler::Configuration.default_overrides_path(provider_name)
      end

      def absolute(path)
        File.expand_path(path, @cwd)
      end

      def present?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def debug_diagnostics(result, enabled)
        return unless enabled

        result.diagnostics.each do |diagnostic|
          @presenter.debug(
            "#{diagnostic.stage}/#{diagnostic.code} state=#{diagnostic.state} " \
            "location=#{diagnostic.location} metadata=#{diagnostic.metadata.inspect}"
          )
        end
      end

      def debug_mapping(result, enabled)
        return unless enabled
        return unless result&.value

        result.value.operations.each do |role, mapping|
          alternatives = Array(mapping.metadata["alternatives"]).map do |item|
            candidate = item["candidate"]
            candidate ? "#{candidate.http_method} #{candidate.path}=#{item['score']}" : nil
          end.compact
          @presenter.debug(
            "operation #{role}=#{mapping.operation.http_method} #{mapping.operation.path} " \
            "score=#{mapping.score} candidates=#{alternatives.join(', ')} evidence=#{mapping.evidence.inspect}"
          )
        end
        result.value.fields.each do |mapping|
          @presenter.debug(
            "field #{mapping.internal_path}=#{mapping.provider_path} score=#{mapping.score} " \
            "evidence=#{mapping.evidence.inspect}"
          )
        end
      end
    end
  end
end
