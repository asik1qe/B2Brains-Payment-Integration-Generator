# frozen_string_literal: true

require_relative "../core/diagnostic"

module ProviderCompiler
  module OpenAPI
    class SupportPolicy
      HTTP_METHODS = %w[get post put patch delete head options trace].freeze
      COMPOSITION_FEATURES = %w[oneOf anyOf allOf not].freeze
      SUPPORTED_SECURITY_TYPES = %w[apikey http].freeze

      def call(document)
        @diagnostics = []
        validate_version(document)
        walk(document)
        validate_content_types(document)
        validate_security_schemes(document)
        validate_operation_servers(document)
        @diagnostics
      end

      private

      def validate_version(document)
        version = value_at(document, "openapi")
        if version.nil? || version.to_s.empty?
          add(:error, :missing_openapi_version, "OpenAPI version is missing", location: "#/openapi")
        elsif !version.to_s.match?(/\A3\.0\.\d+\z/)
          add(
            :error,
            :unsupported_openapi_version,
            "Only OpenAPI 3.0.x is supported",
            location: "#/openapi"
          )
        end
      end

      def walk(value, path = [])
        case value
        when Hash
          value.each do |raw_key, item|
            key = raw_key.to_s
            location = pointer(path + [key])

            if key == "$ref" && item.is_a?(String) && !item.start_with?("#/")
              add(
                :error,
                :external_ref_unsupported,
                "External references are unsupported",
                state: :unresolved,
                location: location
              )
            end

            if COMPOSITION_FEATURES.include?(key)
              add(
                :warning,
                :schema_composition_unsupported,
                "Schema composition feature #{key} requires review",
                state: :needs_review,
                location: location,
                metadata: { "feature" => key }
              )
            end

            walk(item, path + [key])
          end
        when Array
          value.each_with_index { |item, index| walk(item, path + [index.to_s]) }
        end
      end

      def validate_content_types(document)
        each_content_object(document) do |content, location|
          next if content.empty? || content.keys.any? { |media_type| json_media_type?(media_type) }

          add(
            :warning,
            :non_json_content_unsupported,
            "Content object has no JSON media type",
            state: :needs_review,
            location: location,
            metadata: { "media_types" => content.keys.map(&:to_s) }
          )
        end
      end

      def each_content_object(document, &block)
        paths = hash_at(document, "paths")
        paths.each do |path, path_item|
          next unless path_item.is_a?(Hash)

          HTTP_METHODS.each do |method|
            operation = value_at(path_item, method)
            next unless operation.is_a?(Hash)

            yield_content(value_at(operation, "requestBody"), "#/paths/#{escape(path)}/#{method}/requestBody/content", &block)
            responses = hash_at(operation, "responses")
            responses.each do |status, response|
              yield_content(response, "#/paths/#{escape(path)}/#{method}/responses/#{escape(status)}/content", &block)
            end
          end
        end

        components = hash_at(document, "components")
        hash_at(components, "requestBodies").each do |name, request_body|
          yield_content(request_body, "#/components/requestBodies/#{escape(name)}/content", &block)
        end
        hash_at(components, "responses").each do |name, response|
          yield_content(response, "#/components/responses/#{escape(name)}/content", &block)
        end
      end

      def yield_content(owner, location)
        return unless owner.is_a?(Hash)

        content = value_at(owner, "content")
        yield(content, location) if content.is_a?(Hash)
      end

      def validate_security_schemes(document)
        schemes = hash_at(hash_at(document, "components"), "securitySchemes")
        schemes.each do |name, raw_scheme|
          next unless raw_scheme.is_a?(Hash)

          type = value_at(raw_scheme, "type")
          next if type.nil? || SUPPORTED_SECURITY_TYPES.include?(type.to_s.downcase)

          add(
            :warning,
            :security_scheme_unsupported,
            "Security scheme type #{type} requires review",
            state: :needs_review,
            location: "#/components/securitySchemes/#{escape(name)}"
          )
        end
      end

      def validate_operation_servers(document)
        hash_at(document, "paths").each do |path, path_item|
          next unless path_item.is_a?(Hash)

          if path_item.key?("servers") || path_item.key?(:servers)
            unsupported_servers("#/paths/#{escape(path)}/servers")
          end

          HTTP_METHODS.each do |method|
            operation = value_at(path_item, method)
            next unless operation.is_a?(Hash)
            next unless operation.key?("servers") || operation.key?(:servers)

            unsupported_servers("#/paths/#{escape(path)}/#{method}/servers")
          end
        end
      end

      def unsupported_servers(location)
        add(
          :warning,
          :operation_servers_unsupported,
          "Path-level and operation-level servers require review",
          state: :needs_review,
          location: location
        )
      end

      def json_media_type?(media_type)
        base = media_type.to_s.split(";", 2).first.strip.downcase
        base == "application/json" || base.match?(%r{\Aapplication/[^/]+\+json\z})
      end

      def value_at(hash, key)
        return unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_sym]
      end

      def hash_at(hash, key)
        value = value_at(hash, key)
        value.is_a?(Hash) ? value : {}
      end

      def pointer(path)
        "#/#{path.map { |token| escape(token) }.join("/")}"
      end

      def escape(token)
        token.to_s.gsub("~", "~0").gsub("/", "~1")
      end

      def add(severity, code, message, state: nil, location: nil, metadata: {})
        @diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: severity,
          code: code,
          message: message,
          stage: :openapi,
          state: state,
          location: location,
          metadata: metadata
        )
      end
    end
  end
end
