# frozen_string_literal: true

require_relative "operation_mapper"
require_relative "field_mapper"
require_relative "status_mapper"
require_relative "error_mapper"
require_relative "security_mapper"
require_relative "webhook_mapper"
require_relative "overrides"
require_relative "../core/diagnostic"
require_relative "../core/result"
require_relative "../core/mapping/mapping_plan"
require_relative "../core/mapping/operation_mapping"

module ProviderCompiler
  module Mapping
    class Mapper
      def initialize(
        operation_mapper: OperationMapper.new,
        field_mapper: FieldMapper.new,
        status_mapper: StatusMapper.new,
        error_mapper: ErrorMapper.new,
        security_mapper: SecurityMapper.new,
        webhook_mapper: WebhookMapper.new
      )
        @operation_mapper = operation_mapper
        @field_mapper = field_mapper
        @status_mapper = status_mapper
        @error_mapper = error_mapper
        @security_mapper = security_mapper
        @webhook_mapper = webhook_mapper
      end

      def call(provider_spec, overrides: nil)
        diagnostics = []
        override_object, override_diagnostics = load_override_object(overrides)
        diagnostics.concat(override_diagnostics)

        matches = @operation_mapper.call(provider_spec)
        operations = build_operation_mappings(matches, diagnostics)
        if override_object
          operation_override_result = override_object.apply_operation_overrides(operations, provider_spec: provider_spec)
          operations = operation_override_result.value || operations
          diagnostics.concat(operation_override_result.diagnostics)
        end

        fields = @field_mapper.call(provider_spec: provider_spec, operation_matches: operations)
        diagnostics.concat(@field_mapper.diagnostics)

        statuses = @status_mapper.call(provider_spec: provider_spec, operation_matches: operations)
        diagnostics.concat(@status_mapper.diagnostics)

        errors = @error_mapper.call(provider_spec: provider_spec, operation_matches: operations)
        diagnostics.concat(@error_mapper.diagnostics)

        security = @security_mapper.call(provider_spec: provider_spec, operation_matches: operations)
        diagnostics.concat(@security_mapper.diagnostics)

        webhook = @webhook_mapper.call(operations["process_callback"])
        diagnostics.concat(@webhook_mapper.diagnostics)
        diagnostics.concat(critical_operation_diagnostics(operations))

        request_variants = if @field_mapper.respond_to?(:request_variants)
                             @field_mapper.request_variants
                           else
                             []
                           end
        unknown_requisites = if @field_mapper.respond_to?(:unknown_requisites)
                               @field_mapper.unknown_requisites
                             else
                               []
                             end
        request_constants, constant_diagnostics = request_constant_mappings(
          operations["create_request"]&.operation,
          fields,
          request_variants,
          unknown_requisites
        )
        diagnostics.concat(constant_diagnostics)

        metadata = { "openapi_version" => provider_spec.openapi_version, "api_version" => provider_spec.api_version }
        request_headers = request_header_mappings(operations["create_request"]&.operation)
        create_parameter_constants, create_parameter_diagnostics = request_parameter_mappings(
          operations["create_request"]&.operation,
          fields,
          request_headers,
          role: "create_request"
        )
        fetch_parameter_constants, fetch_parameter_diagnostics = request_parameter_mappings(
          operations["fetch_status"]&.operation,
          fields,
          [],
          role: "fetch_status"
        )
        parameter_constants = create_parameter_constants + fetch_parameter_constants
        diagnostics.concat(create_parameter_diagnostics)
        diagnostics.concat(fetch_parameter_diagnostics)
        conditions, condition_diagnostics = build_conditions(
          operations["create_request"]&.operation,
          fields: fields,
          request_headers: request_headers,
          parameter_constants: create_parameter_constants
        )
        diagnostics.concat(condition_diagnostics)
        metadata["request_headers"] = request_headers unless request_headers.empty?
        metadata["request_parameter_constants"] = parameter_constants unless parameter_constants.empty?
        metadata["request_variants"] = request_variants unless request_variants.empty?
        metadata["unknown_requisites"] = unknown_requisites unless unknown_requisites.empty?
        metadata["request_constants"] = request_constants unless request_constants.empty?
        metadata.merge!(connection_metadata(provider_spec, operations, diagnostics))
        diagnostics = deduplicate(diagnostics)

        plan = ProviderCompiler::Core::Mapping::MappingPlan.new(
          provider_name: provider_spec.title,
          operations: operations,
          fields: fields,
          statuses: statuses,
          errors: errors,
          security: security,
          webhook: webhook,
          conditions: conditions,
          diagnostics: diagnostics,
          metadata: metadata
        )

        return override_object.apply(plan, provider_spec: provider_spec) if override_object

        result(plan, diagnostics)
      rescue StandardError => error
        diagnostic = ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: :mapping_error,
          message: "Unable to build mapping plan: #{error.message}",
          stage: :mapping,
          state: :unresolved
        )
        ProviderCompiler::Core::Result.failure(nil, diagnostics: [diagnostic])
      end

      private

      def build_operation_mappings(matches, diagnostics)
        matches.each_with_object({}) do |(role, match), result|
          if match.candidate.nil? || match.unresolved?
            diagnostics << mapping_diagnostic(
              :error,
              :operation_mapping_unresolved,
              "No reliable operation found for #{role}",
              :unresolved,
              role,
              match
            )
            next
          end

          if match.needs_review?
            diagnostics << mapping_diagnostic(
              :warning,
              :operation_mapping_needs_review,
              "Operation mapping for #{role} requires review",
              :needs_review,
              role,
              match
            )
            diagnostics << mapping_diagnostic(
              :error,
              :critical_operation_mapping_needs_review,
              "Critical operation mapping for #{role} requires an explicit override",
              :unresolved,
              role,
              match
            )
          end
          result[role] = ProviderCompiler::Core::Mapping::OperationMapping.new(
            role: role,
            operation: match.candidate,
            decision: match.decision,
            score: match.score,
            evidence: match.evidence,
            metadata: match.metadata.merge("alternatives" => match.alternatives)
          )
        end
      end

      def build_conditions(operation, fields: [], request_headers: [], parameter_constants: [])
        return [[], []] unless operation

        conditions = []
        diagnostics = []
        if operation.request_body&.schema
          walk_schema(operation.request_body.schema) do |path, schema, required|
            append_schema_conditions(
              conditions,
              path,
              schema,
              required,
              "source" => "request_body"
            )

            if schema.description.to_s.match?(/required\s+(?:if|when)|обязател(?:ен|ьна|ьно|ьны)\s+(?:для|если|при)/i)
              diagnostics << ProviderCompiler::Core::Diagnostic.new(
                severity: :warning,
                code: :conditional_rule_needs_review,
                message: "Text-only conditional rule requires an explicit override",
                stage: :mapping,
                state: :needs_review,
                location: path,
                metadata: { "description" => schema.description }
              )
            end
          end
        end

        mapped_parameters = fields.select do |field|
          metadata = field.metadata
          field.request? &&
            (metadata["operation_role"] || metadata[:operation_role]).to_s == "create_request" &&
            (metadata["source"] || metadata[:source]).to_s == "parameter"
        end
        known_parameter_keys = mapped_parameters.map do |field|
          [(field.metadata["location"] || field.metadata[:location]).to_s.downcase, field.provider_path.to_s]
        end
        known_parameter_keys.concat(Array(request_headers).map do |item|
          mapping = stringify_hash(item)
          ["header", mapping["provider_name"].to_s]
        end)
        known_parameter_keys.concat(Array(parameter_constants).map do |item|
          mapping = stringify_hash(item)
          [mapping["location"].to_s.downcase, mapping["provider_name"].to_s]
        end)

        operation.parameters.each do |parameter|
          key = [parameter.location.to_s.downcase, parameter.name.to_s]
          next unless known_parameter_keys.include?(key)

          append_schema_conditions(
            conditions,
            parameter.name.to_s,
            parameter.schema,
            parameter.required == true,
            "source" => "parameter",
            "location" => parameter.location.to_s
          )
        end
        [conditions, diagnostics]
      end

      def append_schema_conditions(conditions, path, schema, required, metadata = {})
        return unless schema

        conditions << metadata.merge("provider_path" => path, "kind" => "required", "value" => true) if required
        {
          "minimum" => schema.minimum,
          "maximum" => schema.maximum,
          "enum" => schema.enum,
          "pattern" => schema.pattern,
          "min_length" => schema.min_length,
          "max_length" => schema.max_length
        }.each do |kind, value|
          conditions << metadata.merge("provider_path" => path, "kind" => kind, "value" => value) unless value.nil?
        end
      end

      def request_constant_mappings(operation, fields, request_variants, unknown_requisites)
        schema = operation&.request_body&.schema
        return [[], []] unless schema

        covered_paths = fields.select do |field|
          field.request? && (field.metadata["operation_role"] || field.metadata[:operation_role]).to_s == "create_request" &&
            (field.metadata["source"] || field.metadata[:source]).to_s == "request_body"
        end.map { |field| field.provider_path.to_s }
        variant_constants = Array(request_variants).flat_map do |variant|
          stringify_hash(variant["constants"] || variant[:constants] || {}).keys
        end
        unknown_paths = Array(unknown_requisites).filter_map do |entry|
          entry.is_a?(Hash) ? (entry["provider_path"] || entry[:provider_path]).to_s : entry.to_s
        end

        constants = []
        diagnostics = []
        required_leaf_schemas(schema).each do |path, leaf_schema|
          next if provider_path_covered?(path, covered_paths)
          next if variant_constants.include?(path)
          next if provider_path_covered?(path, unknown_paths)

          enum = Array(leaf_schema.enum)
          if enum.size == 1
            constants << {
              "operation_role" => "create_request",
              "provider_path" => path,
              "value" => enum.first,
              "required" => true,
              "decision" => "auto",
              "evidence" => [{
                "rule" => "single_enum_required_constant",
                "value" => enum.first
              }]
            }
            next
          end

          diagnostics << ProviderCompiler::Core::Diagnostic.new(
            severity: :error,
            code: :required_request_field_unresolved,
            message: "Required provider request field has no safe platform mapping or constant",
            stage: :mapping,
            state: :unresolved,
            location: path,
            metadata: {
              "operation_role" => "create_request",
              "provider_path" => path,
              "provider_type" => leaf_schema.type,
              "enum" => leaf_schema.enum
            }
          )
        end
        [constants, diagnostics]
      end

      def required_leaf_schemas(schema, prefix = nil, parent_required = true, result = [])
        return result unless schema

        schema.properties.each do |name, child|
          path = [prefix, name].compact.join(".")
          required = parent_required && schema.required?(name)
          if child.properties.any?
            required_leaf_schemas(child, path, required, result)
          elsif required
            result << [path, child]
          end
        end
        result
      end

      def provider_path_covered?(path, candidates)
        Array(candidates).any? do |candidate|
          candidate = candidate.to_s
          path == candidate || path.start_with?("#{candidate}.")
        end
      end

      def connection_metadata(provider_spec, operations, diagnostics)
        outbound = %w[create_request fetch_status].filter_map { |role| operations[role]&.operation }
        root_backed = outbound.select { |operation| operation.server_source.to_s == "root" && operation.servers.any? }
        return {} if root_backed.empty?

        resolved = root_backed.filter_map do |operation|
          resolve_server_url(operation.servers.first, diagnostics, operation)
        end
        return {} if resolved.empty?

        if resolved.uniq.size > 1
          diagnostics << ProviderCompiler::Core::Diagnostic.new(
            severity: :error,
            code: :outbound_root_server_inconsistent,
            message: "Selected outbound operations resolve to different root server URLs",
            stage: :mapping,
            state: :unresolved,
            location: "servers",
            metadata: { "urls" => resolved.uniq }
          )
          return {}
        end

        {
          "base_url" => resolved.first,
          "base_url_source" => "root",
          "server_candidates" => provider_spec.servers.map(&:url)
        }
      end

      def resolve_server_url(server, diagnostics, operation)
        url = server.url.to_s
        unresolved_variables = []
        resolved = url.gsub(/\{([^{}]+)\}/) do
          name = Regexp.last_match(1)
          definition = server.variable(name)
          default = definition.is_a?(Hash) ? (definition["default"] || definition[:default]) : nil
          if default.nil?
            unresolved_variables << name
            Regexp.last_match(0)
          else
            default.to_s
          end
        end
        unless unresolved_variables.empty?
          diagnostics << ProviderCompiler::Core::Diagnostic.new(
            severity: :error,
            code: :server_variable_default_missing,
            message: "Selected root server contains variables without defaults",
            stage: :mapping,
            state: :unresolved,
            location: operation.path,
            metadata: { "variables" => unresolved_variables, "url" => url }
          )
          return nil
        end
        resolved
      end

      def stringify_hash(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end

      def request_parameter_mappings(operation, fields, request_headers, role:)
        return [[], []] unless operation

        mapped = fields.select do |field|
          metadata = field.metadata
          field.request? &&
            (metadata["operation_role"] || metadata[:operation_role]).to_s == role.to_s &&
            (metadata["source"] || metadata[:source]).to_s == "parameter"
        end
        header_names = Array(request_headers).map { |item| stringify_hash(item)["provider_name"].to_s.downcase }
        constants = []
        diagnostics = []

        operation.parameters.select { |parameter| parameter.required == true }.each do |parameter|
          covered = mapped.any? do |field|
            location = field.metadata["location"] || field.metadata[:location]
            field.provider_path.to_s == parameter.name.to_s && location.to_s.casecmp?(parameter.location.to_s)
          end
          covered ||= parameter.header? && header_names.include?(parameter.name.to_s.downcase)
          next if covered

          enum = Array(parameter.schema&.enum)
          if enum.size == 1 && !parameter.path?
            constants << {
              "operation_role" => role.to_s,
              "provider_name" => parameter.name.to_s,
              "location" => parameter.location.to_s,
              "value" => enum.first,
              "required" => true,
              "decision" => "auto",
              "evidence" => [{ "rule" => "single_enum_required_parameter_constant", "value" => enum.first }]
            }
            next
          end

          diagnostics << ProviderCompiler::Core::Diagnostic.new(
            severity: :error,
            code: :required_request_parameter_unresolved,
            message: "Required provider request parameter has no safe platform mapping or constant",
            stage: :mapping,
            state: :unresolved,
            location: parameter.name.to_s,
            metadata: {
              "operation_role" => role.to_s,
              "provider_name" => parameter.name.to_s,
              "location" => parameter.location.to_s,
              "provider_type" => parameter.schema&.type,
              "enum" => parameter.schema&.enum
            }
          )
        end
        [constants, diagnostics]
      end

      def request_header_mappings(operation)
        return [] unless operation

        operation.parameters.filter_map do |parameter|
          tokens = parameter.name.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase.split(/[^a-z0-9]+/)
          next unless parameter.header? && tokens.include?("idempotency")

          {
            "operation_role" => "create_request",
            "provider_name" => parameter.name.to_s,
            "source" => "operation.id",
            "required" => parameter.required == true,
            "decision" => "auto"
          }
        end
      end

      def critical_operation_diagnostics(operations)
        operations.values.flat_map do |mapping|
          operation = mapping.operation
          diagnostics = []
          if operation.request_body&.required && !operation.request_body.json?
            diagnostics << critical_diagnostic(
              :critical_request_media_type_unsupported,
              "Selected operation requires an unsupported non-JSON request body",
              mapping.role,
              "content_type" => operation.request_body.content_type
            )
          end
          if schema_unsupported?(operation.request_body&.schema) ||
             operation.success_responses.values.any? { |response| schema_unsupported?(response.schema) }
            diagnostics << critical_diagnostic(
              :critical_schema_composition_unsupported,
              "Selected operation depends on unsupported schema composition",
              mapping.role
            )
          end
          if %w[path operation].include?(operation.server_source)
            diagnostics << critical_diagnostic(
              :critical_operation_servers_unsupported,
              "Selected operation declares an operation/path-specific server that generation cannot represent",
              mapping.role,
              "server_source" => operation.server_source,
              "servers" => operation.servers.map(&:url)
            )
          end
          diagnostics
        end
      end

      def schema_unsupported?(schema)
        return false unless schema
        return true unless Array(schema.unsupported_features).empty?
        return true if schema.items && schema_unsupported?(schema.items)

        schema.properties.values.any? { |child| schema_unsupported?(child) }
      end

      def critical_diagnostic(code, message, role, metadata = {})
        ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :mapping,
          state: :unresolved,
          location: role.to_s,
          metadata: metadata
        )
      end

      def walk_schema(schema, prefix = nil, &block)
        schema.properties.each do |name, child|
          path = [prefix, name].compact.join(".")
          yield(path, child, schema.required?(name))
          walk_schema(child, path, &block)
        end
      end

      def load_override_object(overrides)
        case overrides
        when nil, false
          [nil, []]
        when Overrides
          [overrides, []]
        when Hash
          [Overrides.new(overrides), []]
        when String
          loaded = Overrides.load(overrides)
          loaded.failure? ? [nil, loaded.diagnostics] : [loaded.value, []]
        else
          diagnostic = ProviderCompiler::Core::Diagnostic.new(
            severity: :error,
            code: :override_invalid,
            message: "Unsupported overrides value",
            stage: :mapping,
            state: :unresolved
          )
          [nil, [diagnostic]]
        end
      end

      def mapping_diagnostic(severity, code, message, state, role, match)
        ProviderCompiler::Core::Diagnostic.new(
          severity: severity,
          code: code,
          message: message,
          stage: :mapping,
          state: state,
          location: role,
          metadata: { "score" => match.score, "evidence" => match.evidence }
        )
      end

      def deduplicate(diagnostics)
        diagnostics.uniq { |item| [item.code, item.severity, item.state, item.location, item.message] }
      end

      def result(plan, diagnostics)
        if diagnostics.any?(&:blocking?)
          ProviderCompiler::Core::Result.failure(plan, diagnostics: diagnostics)
        else
          ProviderCompiler::Core::Result.success(plan, diagnostics: diagnostics)
        end
      end
    end
  end
end
