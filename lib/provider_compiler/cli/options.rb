# frozen_string_literal: true

require "optparse"
require_relative "../configuration"
require_relative "../errors"

module ProviderCompiler
  module CLI
    class Options
      Parsed = Struct.new(
        :spec_path, :provider_name, :output_dir, :overrides_path, :config_path,
        :debug, :non_interactive, :force,
        keyword_init: true
      )

      def parse(argv)
        values = {}
        @help_requested = false
        @parser = build_parser(values)
        @parser.parse!(argv.dup)
        return nil if help?

        Parsed.new(**values)
      end

      def help? = !!@help_requested

      def help_text
        (@parser || build_parser({})).to_s
      end

      private

      def build_parser(values)
        OptionParser.new do |parser|
          parser.banner = "Usage: integrate [options]"
          parser.separator ""
          parser.on("--spec PATH", "OpenAPI YAML or JSON file") { |value| values[:spec_path] = value }
          parser.on("--provider NAME", "Provider name used for generated files") { |value| values[:provider_name] = value }
          parser.on("--output DIR", "Output directory (default: ./output)") { |value| values[:output_dir] = value }
          parser.on("--overrides PATH", "Mapping overrides YAML file") { |value| values[:overrides_path] = value }
          parser.on("--config PATH", "Run configuration YAML file") { |value| values[:config_path] = value }
          parser.on("--debug", "Show detailed diagnostics and source previews") { values[:debug] = true }
          parser.on("--non-interactive", "Never prompt; return NEEDS REVIEW when required") do
            values[:non_interactive] = true
          end
          parser.on("--force", "Overwrite generated files without prompting") { values[:force] = true }
          parser.on("-h", "--help", "Show this help") { @help_requested = true }
          parser.separator ""
          parser.separator "Examples:"
          parser.separator "  integrate --spec provider_api.yaml --provider novapay --output ./output"
          parser.separator "  integrate --spec provider_api.yaml --provider novapay --overrides novapay_overrides.yml --output ./output"
        end
      end

    end
  end
end
