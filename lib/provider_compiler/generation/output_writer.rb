# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "../core/diagnostic"
require_relative "../core/result"

module ProviderCompiler
  module Generation
    class OutputWriter
      def write(generated_integration, output_dir:)
        files = generated_integration.files
        unsafe = files.keys.find { |filename| unsafe_filename?(filename) }
        return failure(:unsafe_output_filename, "Unsafe output filename: #{unsafe}", unsafe) if unsafe

        FileUtils.mkdir_p(output_dir)
        paths = files.each_with_object({}) do |(filename, content), result|
          path = File.join(output_dir, filename)
          File.binwrite(path, content)
          result[filename] = File.expand_path(path)
        end
        ProviderCompiler::Core::Result.success(paths)
      rescue StandardError => error
        failure(:output_write_error, "Unable to write generated files: #{error.message}", output_dir)
      end

      private

      def unsafe_filename?(filename)
        value = filename.to_s
        value.empty? || value == "." || value == ".." ||
          value.include?("/") || value.include?("\\") || Pathname.new(value).absolute? ||
          File.basename(value) != value
      end

      def failure(code, message, location)
        diagnostic = ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :generation,
          state: :unresolved,
          location: location.to_s
        )
        ProviderCompiler::Core::Result.failure(nil, diagnostics: [diagnostic])
      end
    end
  end
end
