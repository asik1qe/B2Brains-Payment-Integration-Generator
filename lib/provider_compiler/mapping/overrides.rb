# frozen_string_literal: true

require "yaml"
require_relative "../core/diagnostic"
require_relative "../core/result"
require_relative "../core/mapping/mapping_plan"
require_relative "../core/mapping/operation_mapping"
require_relative "../core/mapping/field_mapping"
require_relative "../core/mapping/status_mapping"
require_relative "../core/mapping/security_mapping"
require_relative "../core/mapping/webhook_mapping"

module ProviderCompiler
  module Mapping
    class Overrides
      def self.load(path)
        content = File.read(path, encoding: "UTF-8")
        data = YAML.safe_load(
          content,
          permitted_classes: [],
          permitted_symbols: [],
          aliases: false
        )
        ProviderCompiler::Core::Result.success(new(data || {}))
      rescue StandardError => error
        diagnostic = ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: :override_parse_error,
          message: "Unable to load overrides: #{error.message}",
          stage: :mapping,
          state: :unresolved,
          location: path.to_s
        )
        ProviderCompiler::Core::Result.failure(nil, diagnostics: [diagnostic])
      end

      def initialize(data)
        @valid = data.is_a?(Hash)
        @data = @valid ? stringify(data) : {}
      end

      def apply_operation_overrides(existing, provider_spec:)
        diagnostics = []
        diagnostics << invalid_diagnostic("Overrides root must be an object") unless @valid
        operations = apply_operations(existing, provider_spec, diagnostics)
        result(operations, diagnostics)
      end

      def apply(mapping_plan, provider_spec:)
        diagnostics = mapping_plan.diagnostics.dup
        diagnostics << invalid_diagnostic("Overrides root must be an object") unless @valid

        operations = apply_operations(mapping_plan.operations, provider_spec, diagnostics)
        fields = apply_fields(mapping_plan.fields, diagnostics, mapping_plan.operations)
        statuses = apply_statuses(mapping_plan.statuses, diagnostics)
        security = apply_security(mapping_plan.security, diagnostics)
        webhook = apply_webhook(mapping_plan.webhook, diagnostics)
        conditions = apply_conditions(mapping_plan.conditions, diagnostics)
        diagnostics = resolved_diagnostics(diagnostics, fields, security, webhook)
        metadata = resolved_metadata(mapping_plan.metadata)

        plan = ProviderCompiler::Core::Mapping::MappingPlan.new(
          provider_name: mapping_plan.provider_name,
          operations: operations,
          fields: fields,
          statuses: statuses,
          errors: mapping_plan.errors,
          security: security,
          webhook: webhook,
          conditions: conditions,
          diagnostics: diagnostics,
          metadata: metadata
        )
        result(plan, diagnostics)
      end

      private

      def apply_operations(existing, provider_spec, diagnostics)
        overrides = @data["operations"]
        return existing.dup unless overrides.is_a?(Hash)

        result = existing.dup
        overrides.each do |role, selector|
          unless selector.is_a?(Hash)
            diagnostics << invalid_diagnostic("Operation override for #{role} must be an object")
            next
          end

          operation = find_operation(provider_spec, selector)
          unless operation
            diagnostics << ProviderCompiler::Core::Diagnostic.new(
              severity: :error,
              code: :override_operation_not_found,
              message: "Operation override for #{role} did not match an operation",
              stage: :mapping,
              state: :unresolved,
              location: role.to_s,
              metadata: selector
            )
            next
          end

          previous = result[role.to_s]
          result[role.to_s] = ProviderCompiler::Core::Mapping::OperationMapping.new(
            role: role,
            operation: operation,
            decision: :manual,
            score: previous&.score,
            evidence: Array(previous&.evidence) + [{ "rule" => "operation_override" }],
            metadata: (previous&.metadata || {}).merge("override" => selector)
          )
        end
        result
      end

      def find_operation(provider_spec, selector)
        if present?(selector["operation_id"])
          provider_spec.operations.find { |operation| operation.operation_id.to_s == selector["operation_id"].to_s }
        elsif present?(selector["method"]) && present?(selector["path"])
          provider_spec.operation(http_method: selector["method"], path: selector["path"])
        end
      end

      def apply_fields(existing, diagnostics, operations)
        entries = field_override_entries
        return existing.dup if entries.empty?

        result = existing.dup
        entries.group_by(&:first).each do |internal_path, grouped|
          patches = grouped.map(&:last)
          patches.each do |patch|
            unless patch.is_a?(Hash)
              diagnostics << invalid_diagnostic("Field override for #{internal_path} must be an object")
              next
            end

            requested_direction = patch["direction"]&.to_s&.downcase
            provider_path = patch["provider_path"]
            same_direction = result.each_index.select do |index|
              mapping = result[index]
              mapping.internal_path == internal_path &&
                (requested_direction.nil? || mapping.direction == requested_direction)
            end
            exact = same_direction.select do |index|
              provider_path && result[index].provider_path == provider_path
            end

            if provider_path.nil? && same_direction.empty?
              diagnostics << invalid_diagnostic("Field override for #{internal_path} needs direction and provider_path")
              next
            end

            targets = if provider_path.nil?
                        same_direction
                      elsif exact.any?
                        exact
                      elsif patches.length == 1 && same_direction.length == 1
                        same_direction
                      else
                        [nil]
                      end

            targets.each do |index|
              previous = index && result[index]
              direction = previous&.direction || requested_direction
              selected_provider_path = provider_path || previous&.provider_path
              unless present?(direction) && present?(selected_provider_path)
                diagnostics << invalid_diagnostic("Field override for #{internal_path} needs direction and provider_path")
                next
              end
              base_metadata = previous&.metadata || default_field_metadata(internal_path, direction)
              replacement = ProviderCompiler::Core::Mapping::FieldMapping.new(
                internal_path: internal_path,
                provider_path: selected_provider_path,
                direction: direction,
                transformation: patch.key?("transformation") ? patch["transformation"] : previous&.transformation,
                required: patch.key?("required") ? patch["required"] : (previous&.required || false),
                decision: :manual,
                score: previous&.score,
                evidence: Array(previous&.evidence) + [{ "rule" => "field_override" }],
                metadata: base_metadata.merge("override" => patch)
              )
              index ? result[index] = replacement : result << replacement
            end
            materialize_confirmed_uses(result, internal_path, provider_path, operations)
          end

          # Multiple explicit bindings are authoritative as a set. Drop stale
          # inferred mappings for the same internal path/direction so an old
          # automatic guess cannot survive beside the user's choices.
          explicit_by_direction = patches.filter_map do |patch|
            next unless patch.is_a?(Hash) && present?(patch["provider_path"])
            [patch.fetch("direction", "request").to_s.downcase, patch["provider_path"].to_s]
          end.group_by(&:first)
          explicit_by_direction.each do |direction, pairs|
            selected = pairs.map(&:last)
            result.reject! do |field|
              field.internal_path == internal_path && field.direction == direction &&
                !field.manual? && !selected.include?(field.provider_path.to_s)
            end
          end
        end
        result
      end

      def materialize_confirmed_uses(fields, internal_path, provider_path, operations)
        return unless internal_path == "operation.provider_operation_key" && present?(provider_path)

        operations.each do |role, mapping|
          operation = mapping.operation
          operation.parameters.each do |parameter|
            next unless parameter.name.to_s == provider_path.to_s

            add_confirmed_field(
              fields, internal_path, provider_path, "request",
              "operation_role" => role.to_s,
              "source" => "parameter",
              "location" => parameter.location
            )
          end
          operation.success_responses.each_value do |response|
            next unless schema_path?(response.schema, provider_path)

            add_confirmed_field(
              fields, internal_path, provider_path, "response",
              "operation_role" => role.to_s,
              "source" => "response"
            )
          end
        end
      end

      def add_confirmed_field(fields, internal_path, provider_path, direction, metadata)
        existing = fields.find do |field|
          field.internal_path == internal_path && field.provider_path == provider_path &&
            field.direction == direction && field.metadata["operation_role"] == metadata["operation_role"]
        end
        return if existing&.manual?

        replacement = ProviderCompiler::Core::Mapping::FieldMapping.new(
          internal_path: internal_path,
          provider_path: provider_path,
          direction: direction,
          transformation: existing&.transformation,
          decision: :manual,
          evidence: Array(existing&.evidence) + [{ "rule" => "confirmed_field_override" }],
          metadata: (existing&.metadata || {}).merge(metadata).merge("override" => true)
        )
        existing ? fields[fields.index(existing)] = replacement : fields << replacement
      end

      def schema_path?(schema, path)
        path.to_s.split(".").reduce(schema) { |current, token| current&.property(token) } != nil
      end

      def apply_statuses(existing, diagnostics)
        patch = @data["statuses"]
        return existing unless patch.is_a?(Hash)

        unless existing
          existing = ProviderCompiler::Core::Mapping::StatusMapping.new(decision: :unresolved)
        end
        ProviderCompiler::Core::Mapping::StatusMapping.new(
          mappings: existing.mappings.merge(patch.transform_keys(&:to_s)),
          decision: :manual,
          evidence: existing.evidence + [{ "rule" => "status_override" }],
          unknown_status: existing.unknown_status,
          metadata: existing.metadata.merge("override" => patch)
        )
      rescue StandardError => error
        diagnostics << invalid_diagnostic("Invalid status override: #{error.message}")
        existing
      end

      def apply_security(existing, diagnostics)
        patch = @data["security"]
        return existing unless patch.is_a?(Hash)

        candidate = Array(existing&.metadata&.fetch("alternatives", [])).map { |item| stringify(item) }.find do |item|
          present?(patch["scheme_key"]) && item["scheme_key"].to_s == patch["scheme_key"].to_s
        end
        type = patch["type"] || candidate&.fetch("type", nil) || existing&.type
        unless present?(type)
          diagnostics << invalid_diagnostic("Security override needs type when no mapping exists")
          return existing
        end
        unless %w[apikey bearer basic].include?(type.to_s.downcase)
          diagnostics << invalid_diagnostic("Security override type #{type} is unsupported")
          return existing
        end
        ProviderCompiler::Core::Mapping::SecurityMapping.new(
          scheme_key: patch.fetch("scheme_key", candidate&.fetch("scheme_key", nil) || existing&.scheme_key),
          type: type,
          location: patch.fetch("location", candidate&.fetch("location", nil) || existing&.location),
          name: patch.fetch("name", candidate&.fetch("name", nil) || existing&.name),
          credential_path: patch.fetch("credential_path", candidate&.fetch("credential_path", nil) || existing&.credential_path),
          prefix: patch.fetch("prefix", candidate&.fetch("prefix", nil) || existing&.prefix),
          parameters: patch.fetch("parameters", candidate&.fetch("parameters", nil) || existing&.parameters || {}),
          decision: :manual,
          evidence: Array(existing&.evidence) + [{ "rule" => "security_override" }],
          metadata: (existing&.metadata || {}).merge("override" => patch)
        )
      end

      def apply_webhook(existing, diagnostics)
        patch = @data["webhook"]
        return existing unless patch.is_a?(Hash)
        unless existing
          diagnostics << invalid_diagnostic("Webhook override requires an existing webhook mapping")
          return nil
        end

        ProviderCompiler::Core::Mapping::WebhookMapping.new(
          operation: existing.operation,
          event_path: patch.fetch("event_path", existing.event_path),
          status_path: patch.fetch("status_path", existing.status_path),
          provider_operation_id_path: patch.fetch("provider_operation_id_path", existing.provider_operation_id_path),
          external_id_path: patch.fetch("external_id_path", existing.external_id_path),
          error_path: patch.fetch("error_path", existing.error_path),
          signature_header: patch.fetch("signature_header", existing.signature_header),
          signature_algorithm: patch.fetch("signature_algorithm", existing.signature_algorithm),
          signature_encoding: patch.fetch("signature_encoding", existing.signature_encoding),
          signed_payload: patch.fetch("signed_payload", existing.signed_payload),
          secret_credential_path: patch.fetch("secret_credential_path", existing.secret_credential_path),
          events: patch.fetch("events", existing.events),
          decision: :manual,
          evidence: existing.evidence + [{ "rule" => "webhook_override" }],
          metadata: existing.metadata.merge("override" => patch)
        )
      end

      def apply_conditions(existing, diagnostics)
        additions = @data["conditions"]
        return existing.dup unless additions.is_a?(Array)

        result = existing.map { |condition| stringify(condition) }
        additions.each do |condition|
          unless condition.is_a?(Hash) && present?(condition["provider_path"])
            diagnostics << invalid_diagnostic("Each condition override needs provider_path")
            next
          end

          normalized = stringify(condition)
          result.reject! do |current|
            current["provider_path"] == normalized["provider_path"] && condition_kind(current) == condition_kind(normalized)
          end
          result << normalized
        end
        result
      end

      def condition_kind(condition)
        condition["kind"] || ("required_if" if condition.key?("required_if"))
      end

      def resolved_diagnostics(diagnostics, fields, security, webhook)
        result = diagnostics.dup
        field_paths = field_override_entries.map(&:first).uniq
        result.reject! do |diagnostic|
          %w[money_unit_needs_review transformation_incomplete].include?(diagnostic.code) &&
            field_paths.include?(diagnostic.location.to_s) &&
            fields.select { |field| field.internal_path == diagnostic.location.to_s }.all?(&:manual?)
        end

        if @data["security"].is_a?(Hash) && security&.manual?
          result.reject! do |diagnostic|
            %w[security_mapping_needs_review security_mapping_unresolved].include?(diagnostic.code)
          end
        end
        result.reject! do |diagnostic|
          %w[field_mapping_needs_review field_mapping_unresolved].include?(diagnostic.code) &&
            field_paths.include?(diagnostic.location.to_s) &&
            fields.any? { |field| field.internal_path == diagnostic.location.to_s } &&
            fields.select { |field| field.internal_path == diagnostic.location.to_s }.all?(&:manual?)
        end

        confirmed_paths = confirmed_provider_paths
        result.reject! do |diagnostic|
          diagnostic.code == "required_request_field_unresolved" &&
            provider_path_confirmed?(diagnostic.location.to_s, confirmed_paths)
        end

        operation_roles = @data["operations"].is_a?(Hash) ? @data["operations"].keys.map(&:to_s) : []
        result.reject! do |diagnostic|
          %w[operation_mapping_needs_review critical_operation_mapping_needs_review].include?(diagnostic.code) &&
            operation_roles.include?(diagnostic.location.to_s)
        end

        result = resolve_requisite_diagnostics(result)

        webhook_patch = @data["webhook"]
        if webhook_patch.is_a?(Hash) && webhook&.manual?
          result.reject! do |diagnostic|
            next false unless diagnostic.code == "webhook_field_mapping_unresolved"

            field = diagnostic.metadata["field"] || diagnostic.location
            value = webhook.respond_to?(field.to_s) ? webhook.public_send(field.to_s) : nil
            present?(value)
          end
        end
        if webhook_patch.is_a?(Hash) && %w[signature_encoding signed_payload secret_credential_path].all? { |key| present?(webhook_patch[key]) }
          result.reject! { |diagnostic| diagnostic.code == "webhook_mapping_needs_review" }
        end

        condition_paths = Array(@data["conditions"]).filter_map do |condition|
          condition["provider_path"].to_s if condition.is_a?(Hash)
        end
        result.reject! do |diagnostic|
          diagnostic.code == "conditional_rule_needs_review" && condition_paths.include?(diagnostic.location.to_s)
        end
        result
      end

      def resolve_requisite_diagnostics(diagnostics)
        confirmed = confirmed_provider_paths
        return diagnostics if confirmed.empty?

        diagnostics.filter_map do |diagnostic|
          unless %w[payout_requisite_mapping_unresolved payout_requisite_mapping_needs_review].include?(diagnostic.code)
            next diagnostic
          end

          fields = Array(diagnostic.metadata["fields"] || diagnostic.metadata["provider_paths"])
          remaining = fields.reject { |path| provider_path_confirmed?(path, confirmed) }
          next if remaining.empty?

          requisites = Array(diagnostic.metadata["requisites"]).select do |entry|
            remaining.include?(entry["provider_path"] || entry[:provider_path])
          end
          ProviderCompiler::Core::Diagnostic.new(
            severity: diagnostic.severity,
            code: diagnostic.code,
            message: diagnostic.message,
            stage: diagnostic.stage,
            state: diagnostic.state,
            location: remaining.first,
            metadata: diagnostic.metadata.merge(
              "fields" => remaining,
              "provider_paths" => remaining,
              "requisites" => requisites
            )
          )
        end
      end

      def resolved_metadata(metadata)
        result = stringify(metadata)
        unknown = Array(result["unknown_requisites"])
        remaining = unknown.reject do |entry|
          path = entry.is_a?(Hash) ? entry["provider_path"] : entry.to_s
          provider_path_confirmed?(path, confirmed_provider_paths)
        end
        if remaining.empty?
          result.delete("unknown_requisites")
        else
          result["unknown_requisites"] = remaining
        end
        result
      end

      def confirmed_provider_paths
        field_override_entries.filter_map do |_internal_path, patch|
          patch["provider_path"].to_s if patch.is_a?(Hash) && present?(patch["provider_path"])
        end
      end

      def field_override_entries
        fields = @data["fields"]
        return [] unless fields.is_a?(Hash)

        fields.flat_map do |internal_path, value|
          patches = value.is_a?(Array) ? value : [value]
          patches.map { |patch| [internal_path.to_s, patch] }
        end
      end

      def provider_path_confirmed?(path, confirmed)
        confirmed.any? { |candidate| path.to_s == candidate || path.to_s.start_with?("#{candidate}.") }
      end

      def default_field_metadata(internal_path, direction)
        if internal_path == "operation.provider_operation_key"
          source = direction == "response" ? "response" : "parameter"
          role = direction == "response" ? "create_request" : "fetch_status"
          { "operation_role" => role, "source" => source }
        else
          { "operation_role" => "create_request", "source" => "request_body" }
        end
      end

      def invalid_diagnostic(message)
        ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: :override_invalid,
          message: message,
          stage: :mapping,
          state: :unresolved
        )
      end

      def result(value, diagnostics)
        if diagnostics.any?(&:blocking?)
          ProviderCompiler::Core::Result.failure(value, diagnostics: diagnostics)
        else
          ProviderCompiler::Core::Result.success(value, diagnostics: diagnostics)
        end
      end

      def stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
        when Array
          value.map { |item| stringify(item) }
        else
          value
        end
      end

      def present?(value)
        !value.nil? && (!value.respond_to?(:empty?) || !value.empty?)
      end
    end
  end
end
