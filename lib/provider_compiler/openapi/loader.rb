# frozen_string_literal: true

require "json"
require "yaml"
require_relative "../core/result"
require_relative "../core/diagnostic"

module ProviderCompiler
  module OpenAPI
    class Loader
      def call(path)
        content = File.read(path)
        document = parse(content, path)

        unless document.is_a?(Hash)
          return failure(
            :openapi_root_not_object,
            "OpenAPI document root must be an object",
            location: path.to_s
          )
        end

        ProviderCompiler::Core::Result.success(document)
      rescue Errno::ENOENT
        failure(:openapi_file_not_found, "OpenAPI file was not found", location: path.to_s)
      rescue JSON::ParserError, Psych::Exception => error
        failure(:openapi_parse_error, error.message, location: path.to_s)
      rescue SystemCallError, IOError, TypeError => error
        failure(:openapi_read_error, error.message, location: path.to_s)
      end

      private

      def parse(content, path)
        case File.extname(path.to_s).downcase
        when ".json"
          JSON.parse(content)
        when ".yaml", ".yml"
          parse_yaml(content)
        else
          content.lstrip.start_with?("{", "[") ? JSON.parse(content) : parse_yaml(content)
        end
      end

      def parse_yaml(content)
        YAML.safe_load(
          content,
          permitted_classes: [],
          permitted_symbols: [],
          aliases: false
        )
      end

      def failure(code, message, location: nil)
        diagnostic = ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :openapi,
          state: :unresolved,
          location: location
        )
        ProviderCompiler::Core::Result.failure(nil, diagnostics: [diagnostic])
      end
    end
  end
end
