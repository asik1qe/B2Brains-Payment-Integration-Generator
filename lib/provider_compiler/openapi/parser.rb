# frozen_string_literal: true

require_relative "normalizer"
require_relative "support_policy"
require_relative "ref_resolver"
require_relative "schema_parser"
require_relative "../core/result"
require_relative "../core/diagnostic"
require_relative "../core/api/provider_spec"
require_relative "../core/api/operation"
require_relative "../core/api/parameter"
require_relative "../core/api/request_body"
require_relative "../core/api/response"
require_relative "../core/api/security_scheme"
require_relative "../core/api/server"

module ProviderCompiler
  module OpenAPI
    class Parser
      HTTP_METHODS = %w[get post put patch delete head options trace].freeze

      def call(document)
        return invalid_document_result unless document.is_a?(Hash)

        normalized = Normalizer.new.call(document)
        @diagnostics = SupportPolicy.new.call(normalized)
        @ref_resolver = RefResolver.new(normalized)
        @schema_parser = SchemaParser.new(normalized, ref_resolver: @ref_resolver)

        version = normalized["openapi"]
        return build_result(nil) if version.nil? || version.to_s.empty?

        info = normalized["info"].is_a?(Hash) ? normalized["info"] : {}
        servers = parse_servers(normalized["servers"])
        provider_spec = ProviderCompiler::Core::API::ProviderSpec.new(
          openapi_version: version,
          title: info["title"],
          description: info["description"],
          api_version: info["version"],
          servers: servers,
          operations: parse_operations(normalized["paths"], root_servers: servers),
          schemas: parse_component_schemas(normalized.dig("components", "schemas")),
          security_schemes: parse_security_schemes(normalized.dig("components", "securitySchemes")),
          global_security: security_value(normalized, "security"),
          tags: normalized["tags"].is_a?(Array) ? normalized["tags"] : [],
          extensions: extract_extensions(normalized)
        )

        build_result(provider_spec)
      rescue StandardError => error
        @diagnostics ||= []
        add_diagnostic(
          :error,
          :openapi_parser_error,
          "Unable to parse OpenAPI document: #{error.message}",
          state: :unresolved
        )
        build_result(nil)
      end

      private

      def invalid_document_result
        @diagnostics = []
        add_diagnostic(
          :error,
          :invalid_openapi_document,
          "OpenAPI document must be an object",
          state: :unresolved
        )
        build_result(nil)
      end

      def parse_servers(raw_servers)
        return [] unless raw_servers.is_a?(Array)

        raw_servers.filter_map.with_index do |raw_server, index|
          unless raw_server.is_a?(Hash) && present?(raw_server["url"])
            add_diagnostic(
              :warning,
              :invalid_server,
              "Server must contain a non-empty URL",
              state: :needs_review,
              location: "#/servers/#{index}"
            )
            next
          end

          ProviderCompiler::Core::API::Server.new(
            url: raw_server["url"],
            description: raw_server["description"],
            variables: raw_server["variables"].is_a?(Hash) ? raw_server["variables"] : {},
            extensions: extract_extensions(raw_server)
          )
        end
      end

      def parse_component_schemas(raw_schemas)
        return {} unless raw_schemas.is_a?(Hash)

        raw_schemas.each_with_object({}) do |(name, raw_schema), result|
          schema = @schema_parser.parse(raw_schema, name: name.to_s)
          result[name.to_s] = schema unless schema.nil?
        end
      end

      def parse_security_schemes(raw_schemes)
        return {} unless raw_schemes.is_a?(Hash)

        raw_schemes.each_with_object({}) do |(key, raw_scheme), result|
          unless raw_scheme.is_a?(Hash) && present?(raw_scheme["type"])
            add_diagnostic(
              :warning,
              :invalid_security_scheme,
              "Security scheme must contain a non-empty type",
              state: :needs_review,
              location: "#/components/securitySchemes/#{pointer_escape(key)}"
            )
            next
          end

          result[key.to_s] = ProviderCompiler::Core::API::SecurityScheme.new(
            key: key.to_s,
            type: raw_scheme["type"],
            location: raw_scheme["in"],
            name: raw_scheme["name"],
            scheme: raw_scheme["scheme"],
            bearer_format: raw_scheme["bearerFormat"],
            description: raw_scheme["description"],
            extensions: extract_extensions(raw_scheme)
          )
        end
      end

      def parse_operations(raw_paths, root_servers: [])
        return [] unless raw_paths.is_a?(Hash)

        raw_paths.each_with_object([]) do |(path, raw_path_item), operations|
          next unless raw_path_item.is_a?(Hash)

          path_parameters = parse_parameters(
            raw_path_item["parameters"],
            "#/paths/#{pointer_escape(path)}/parameters"
          )
          path_has_servers = raw_path_item.key?("servers")
          path_servers = path_has_servers ? parse_servers(raw_path_item["servers"]) : root_servers

          HTTP_METHODS.each do |method|
            raw_operation = raw_path_item[method]
            next unless raw_operation.is_a?(Hash)

            operation_parameters = parse_parameters(
              raw_operation["parameters"],
              "#/paths/#{pointer_escape(path)}/#{method}/parameters"
            )
            parameters = merge_parameters(path_parameters, operation_parameters)
            operation_has_servers = raw_operation.key?("servers")
            effective_servers = operation_has_servers ? parse_servers(raw_operation["servers"]) : path_servers
            server_source = if operation_has_servers
                              "operation"
                            elsif path_has_servers
                              "path"
                            elsif root_servers.any?
                              "root"
                            end

            operations << ProviderCompiler::Core::API::Operation.new(
              http_method: method,
              path: path,
              operation_id: raw_operation["operationId"],
              tags: raw_operation["tags"].is_a?(Array) ? raw_operation["tags"] : [],
              summary: raw_operation["summary"],
              description: raw_operation["description"],
              parameters: parameters,
              request_body: parse_request_body(
                raw_operation["requestBody"],
                "#/paths/#{pointer_escape(path)}/#{method}/requestBody"
              ),
              responses: parse_responses(
                raw_operation["responses"],
                "#/paths/#{pointer_escape(path)}/#{method}/responses"
              ),
              security: security_value(raw_operation, "security"),
              servers: effective_servers,
              server_source: server_source,
              deprecated: raw_operation.key?("deprecated") ? raw_operation["deprecated"] : false,
              extensions: extract_extensions(raw_operation)
            )
          end
        end
      end

      def parse_parameters(raw_parameters, location)
        return [] unless raw_parameters.is_a?(Array)

        raw_parameters.filter_map.with_index do |raw_parameter, index|
          parse_parameter(raw_parameter, "#{location}/#{index}")
        end
      end

      def parse_parameter(raw_parameter, location)
        raw = resolve_object(raw_parameter, location)
        unless raw.is_a?(Hash) && present?(raw["name"]) && present?(raw["in"])
          add_diagnostic(
            :warning,
            :invalid_parameter,
            "Parameter must contain non-empty name and in fields",
            state: :needs_review,
            location: location
          )
          return nil
        end

        required = raw.key?("required") ? raw["required"] : false
        if raw["in"].to_s.casecmp?("path") && required != true
          add_diagnostic(
            :warning,
            :path_parameter_not_required,
            "Path parameter is not marked as required",
            state: :needs_review,
            location: location
          )
        end

        ProviderCompiler::Core::API::Parameter.new(
          name: raw["name"],
          location: raw["in"],
          required: required,
          schema: @schema_parser.parse(raw["schema"]),
          description: raw["description"],
          example: raw["example"],
          deprecated: raw.key?("deprecated") ? raw["deprecated"] : false,
          extensions: extract_extensions(raw)
        )
      end

      def merge_parameters(path_parameters, operation_parameters)
        merged = {}
        path_parameters.each { |parameter| merged[parameter_identity(parameter)] = parameter }
        operation_parameters.each { |parameter| merged[parameter_identity(parameter)] = parameter }
        merged.values
      end

      def parameter_identity(parameter)
        [parameter.name.to_s, parameter.location.to_s.downcase]
      end

      def parse_request_body(raw_request_body, location)
        return nil if raw_request_body.nil?

        raw = resolve_object(raw_request_body, location)
        unless raw.is_a?(Hash)
          add_diagnostic(
            :warning,
            :invalid_request_body,
            "Request body must be an object",
            state: :needs_review,
            location: location
          )
          return nil
        end

        content_type, media = select_content(raw["content"])
        ProviderCompiler::Core::API::RequestBody.new(
          required: raw.key?("required") ? raw["required"] : false,
          content_type: content_type,
          schema: media.is_a?(Hash) ? @schema_parser.parse(media["schema"]) : nil,
          examples: parse_examples(media),
          description: raw["description"],
          extensions: extract_extensions(raw)
        )
      end

      def parse_responses(raw_responses, location)
        return {} unless raw_responses.is_a?(Hash)

        raw_responses.each_with_object({}) do |(status_code, raw_response), result|
          response = parse_response(raw_response, status_code, "#{location}/#{pointer_escape(status_code)}")
          result[status_code.to_s] = response unless response.nil?
        end
      end

      def parse_response(raw_response, status_code, location)
        raw = resolve_object(raw_response, location)
        unless raw.is_a?(Hash)
          add_diagnostic(
            :warning,
            :invalid_response,
            "Response must be an object",
            state: :needs_review,
            location: location
          )
          return nil
        end

        content_type, media = select_content(raw["content"])
        ProviderCompiler::Core::API::Response.new(
          status_code: status_code,
          description: raw["description"],
          content_type: content_type,
          schema: media.is_a?(Hash) ? @schema_parser.parse(media["schema"]) : nil,
          headers: parse_headers(raw["headers"], "#{location}/headers"),
          examples: parse_examples(media),
          extensions: extract_extensions(raw)
        )
      end

      def parse_headers(raw_headers, location)
        return {} unless raw_headers.is_a?(Hash)

        raw_headers.each_with_object({}) do |(name, raw_header), result|
          raw = resolve_object(raw_header, "#{location}/#{pointer_escape(name)}")
          next unless raw.is_a?(Hash)

          result[name.to_s] = ProviderCompiler::Core::API::Parameter.new(
            name: name.to_s,
            location: "header",
            required: false,
            schema: @schema_parser.parse(raw["schema"]),
            description: raw["description"],
            example: raw["example"],
            deprecated: raw.key?("deprecated") ? raw["deprecated"] : false,
            extensions: extract_extensions(raw)
          )
        end
      end

      def select_content(raw_content)
        return [nil, nil] unless raw_content.is_a?(Hash) && !raw_content.empty?

        exact = raw_content.keys.find { |key| key.to_s.casecmp?("application/json") }
        selected = exact || raw_content.keys.find { |key| json_suffix_media_type?(key) } || raw_content.keys.first
        [selected.to_s, raw_content[selected]]
      end

      def json_suffix_media_type?(media_type)
        base = media_type.to_s.split(";", 2).first.strip
        base.match?(%r{\Aapplication/[^/]+\+json\z}i)
      end

      def parse_examples(media)
        return {} unless media.is_a?(Hash)

        examples = media["examples"].is_a?(Hash) ? deep_copy(media["examples"]) : {}
        examples["default"] = deep_copy(media["example"]) if media.key?("example") && !examples.key?("default")
        examples
      end

      def security_value(owner, key)
        return nil unless owner.is_a?(Hash) && owner.key?(key)

        security = owner[key]
        return security unless security.is_a?(Array)

        security.map do |requirement|
          next requirement unless requirement.is_a?(Hash)

          requirement.each_with_object({}) do |(scheme, scopes), result|
            result[scheme.to_s] = deep_copy(scopes)
          end
        end
      end

      def resolve_object(raw_object, location, ref_stack = [])
        return raw_object unless raw_object.is_a?(Hash)

        raw = stringify_keys(raw_object)
        ref = raw["$ref"]
        return raw if ref.nil?

        if ref_stack.include?(ref)
          add_diagnostic(
            :error,
            :invalid_ref,
            "Cyclic reusable object reference detected",
            state: :unresolved,
            location: location
          )
          return nil
        end

        target = @ref_resolver.resolve(ref)
        return nil unless target.is_a?(Hash)

        resolved = resolve_object(target, location, ref_stack + [ref])
        return nil unless resolved.is_a?(Hash)

        resolved.merge(raw.reject { |key, _| key == "$ref" })
      end

      def extract_extensions(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value if key.to_s.start_with?("x-")
        end
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end

      def deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key] = deep_copy(item) }
        when Array
          value.map { |item| deep_copy(item) }
        else
          value
        end
      end

      def present?(value)
        !value.nil? && (!value.respond_to?(:empty?) || !value.empty?)
      end

      def pointer_escape(token)
        token.to_s.gsub("~", "~0").gsub("/", "~1")
      end

      def add_diagnostic(severity, code, message, state: nil, location: nil, metadata: {})
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

      def collect_diagnostics
        diagnostics = @diagnostics + @ref_resolver.diagnostics + @schema_parser.diagnostics
        diagnostics.uniq do |diagnostic|
          [diagnostic.severity, diagnostic.code, diagnostic.state, diagnostic.location, diagnostic.message]
        end
      end

      def build_result(value)
        diagnostics = if defined?(@ref_resolver) && defined?(@schema_parser)
                        collect_diagnostics
                      else
                        @diagnostics
                      end
        if diagnostics.any?(&:blocking?)
          ProviderCompiler::Core::Result.failure(value, diagnostics: diagnostics)
        else
          ProviderCompiler::Core::Result.success(value, diagnostics: diagnostics)
        end
      end
    end
  end
end
