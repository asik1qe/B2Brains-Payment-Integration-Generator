# frozen_string_literal: true

require_relative "../core/diagnostic"
require_relative "../core/result"

module ProviderCompiler
  module Generation
    class UrlBuilder
      PATH_PARAMETER = /\{([^{}]+)\}/

      def build(operation_mapping:, field_mappings:)
        operation = operation_mapping.respond_to?(:operation) ? operation_mapping.operation : operation_mapping
        path = operation.path.to_s
        parameters = path.scan(PATH_PARAMETER).flatten
        replacements = {}
        diagnostics = []

        parameters.each do |parameter|
          mapping = path_mapping(field_mappings, operation_mapping, parameter)
          unless mapping
            diagnostics << diagnostic(
              :path_parameter_mapping_missing,
              "No field mapping was provided for path parameter #{parameter}",
              parameter
            )
            next
          end

          expression = mapping.internal_path.to_s
          unless expression.match?(/\A[a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*\z/)
            diagnostics << diagnostic(
              :unsafe_field_expression,
              "Mapped internal path is not a safe Ruby expression",
              mapping.internal_path
            )
            next
          end
          replacements[parameter] = expression
        end

        return ProviderCompiler::Core::Result.failure(nil, diagnostics: diagnostics) unless diagnostics.empty?

        expression = ruby_path_expression(path, replacements)
        ProviderCompiler::Core::Result.success(expression)
      end

      private

      def path_mapping(field_mappings, operation_mapping, parameter)
        role = operation_mapping.respond_to?(:role) ? operation_mapping.role : nil
        field_mappings.find do |mapping|
          next false unless mapping.request? && mapping.provider_path.to_s == parameter

          metadata_role = mapping.metadata["operation_role"] || mapping.metadata[:operation_role]
          location = mapping.metadata["location"] || mapping.metadata[:location]
          (role.nil? || metadata_role.nil? || metadata_role.to_s == role.to_s) &&
            (location.nil? || location.to_s.casecmp?("path"))
        end
      end

      def ruby_path_expression(path, replacements)
        return path.inspect if replacements.empty?

        cursor = 0
        source = +"\""
        path.to_enum(:scan, PATH_PARAMETER).each do
          match = Regexp.last_match
          source << escape_double_quoted(path[cursor...match.begin(0)])
          source << "\#{#{replacements.fetch(match[1])}}"
          cursor = match.end(0)
        end
        source << escape_double_quoted(path[cursor..])
        source << "\""
        source
      end

      def escape_double_quoted(value)
        value.to_s.gsub("\\", "\\\\").gsub("\"", "\\\"").gsub('#{', '\\#{')
      end

      def diagnostic(code, message, location)
        ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :generation,
          state: :unresolved,
          location: location
        )
      end
    end
  end
end
