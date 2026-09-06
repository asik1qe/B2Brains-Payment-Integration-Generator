# frozen_string_literal: true

module ProviderCompiler
  module Generation
    class DocumentationGenerator
      def generate(mapping_plan:, provider_spec: nil, service_filename:)
        lines = ["# #{mapping_plan.provider_name} Integration", ""]
        section(lines, "Generated files / Service") do
          lines << "- Service: `#{service_filename}`"
          lines << "- Documentation: `INTEGRATION.md`"
          lines << "- Fixtures: `fixtures.json`"
        end
        section(lines, "Base URL / Servers") do
          servers = provider_spec&.servers || []
          if servers.empty?
            lines << "No server URL was supplied. Configure it manually."
          else
            servers.each { |server| lines << "- `#{server.url}`#{description_suffix(server.description)}" }
          end
        end
        render_authentication(lines, mapping_plan.security)
        render_runtime_contract(lines, mapping_plan)
        render_operations(lines, mapping_plan)
        render_fields(lines, mapping_plan.fields)
        render_transformations(lines, mapping_plan.fields)
        render_conditions(lines, mapping_plan.conditions)
        render_statuses(lines, mapping_plan.statuses)
        render_errors(lines, mapping_plan.errors)
        render_webhook(lines, mapping_plan.webhook)
        render_gateway(lines, mapping_plan.metadata)
        render_assumptions(lines, mapping_plan, provider_spec)
        lines.join("\n") + "\n"
      end

      private

      def render_runtime_contract(lines, plan)
        section(lines, "Platform runtime contract") do
          lines << "- `create_request` returns provider identity as `success(result: { id: provider_id })`; the platform stores it outside the service."
          lines << "- Status requests read the stored identity from `operation.provider_operation_key`."
          lines << "- Approved/rejected lifecycle transitions use `approve_operation` / `reject_operation`; in-progress returns plain success."
          lines << "- Known requisites: SBP uses `operation.payout_requisite.sbp.*`; card uses `operation.payout_requisite.card_number`."
          variants = Array(plan.metadata["request_variants"] || plan.metadata[:request_variants])
          lines << "- Request variants: #{variants.map { |item| stringify(item)["name"] }.join(', ')}." unless variants.empty?
          unknown = Array(plan.metadata["unknown_requisites"] || plan.metadata[:unknown_requisites])
          unless unknown.empty?
            lines << "- TODO/manual mapping required for unknown provider requisites: #{unknown.map { |item| unknown_requisite_label(item) }.join(', ')}."
          end
        end
      end

      def render_authentication(lines, security)
        section(lines, "Authentication") do
          if security
            lines << "- Type: `#{security.type}`"
            lines << "- Scheme key: `#{security.scheme_key}`" if security.scheme_key
            lines << "- Location: `#{security.location}`" if security.location
            lines << "- Name: `#{security.name}`" if security.name
            lines << "- Credential path: `#{security.credential_path}`" if security.credential_path
            lines << "- Decision: #{decision_label(security.decision)}"
          else
            lines << "No authentication mapping is configured."
          end
        end
      end

      def render_operations(lines, plan)
        section(lines, "Operations") do
          %w[create_request fetch_status process_callback].each do |role|
            mapping = plan.operation(role)
            lines << "### #{role}"
            lines << ""
            if mapping
              lines << "- Endpoint: `#{mapping.operation.http_method} #{mapping.operation.path}`"
              lines << "- Operation ID: `#{mapping.operation.operation_id}`" if mapping.operation.operation_id
              lines << "- Decision: #{decision_label(mapping.decision)}"
              rules = mapping.evidence.filter_map { |item| item["rule"] || item[:rule] }.uniq
              lines << "- Evidence: #{rules.join(', ')}" unless rules.empty?
            else
              lines << "Unresolved."
            end
            lines << ""
          end
        end
      end

      def render_fields(lines, fields)
        section(lines, "Field mapping") do
          if fields.empty?
            lines << "No field mappings."
          else
            lines << "| Internal | Provider | Direction | Decision |"
            lines << "| --- | --- | --- | --- |"
            fields.each do |field|
              lines << "| `#{field.internal_path}` | `#{field.provider_path}` | #{field.direction} | #{decision_label(field.decision)} |"
            end
          end
        end
      end

      def render_transformations(lines, fields)
        section(lines, "Transformations") do
          transformed = fields.select(&:transformed?)
          if transformed.empty?
            lines << "No transformations."
          else
            transformed.each do |field|
              descriptor = field.transformation
              details = descriptor.sort_by { |key, _| key.to_s }.map { |key, value| "#{key}=#{stable_inspect(value)}" }.join(", ")
              lines << "- `#{field.internal_path}` → `#{field.provider_path}`: #{details}"
            end
          end
        end
      end

      def render_conditions(lines, conditions)
        section(lines, "Conditions") do
          if conditions.empty?
            lines << "No structural conditions."
          else
            conditions.each do |condition|
              condition = stringify(condition)
              detail = condition["required_if"] || condition["value"]
              kind = condition["kind"] || "required_if"
              lines << "- `#{condition["provider_path"]}`: #{kind} = `#{stable_inspect(detail)}`"
            end
          end
        end
      end

      def render_statuses(lines, statuses)
        section(lines, "Status mapping") do
          if statuses&.mappings&.any?
            statuses.mappings.each { |provider, internal| lines << "- `#{provider}` → `#{internal}`" }
            lines << "- Decision: #{decision_label(statuses.decision)}"
          else
            lines << "No status mapping."
          end
        end
      end

      def render_errors(lines, errors)
        section(lines, "Error mapping") do
          if errors.empty?
            lines << "No error mappings."
          else
            lines << "| Role | HTTP | Target | Retry | Decision |"
            lines << "| --- | --- | --- | --- | --- |"
            errors.each do |error|
              retry_detail = error.retry_after_header || error.retryable?.to_s
              lines << "| #{error.operation_role} | #{error.http_status} | `#{error.target}` | #{retry_detail} | #{decision_label(error.decision)} |"
            end
          end
        end
      end

      def render_webhook(lines, webhook)
        section(lines, "Webhook") do
          if webhook
            lines << "- Endpoint: `#{webhook.operation.http_method} #{webhook.operation.path}`" if webhook.operation
            lines << "- Event path: `#{webhook.event_path}`" if webhook.event_path
            lines << "- Status path: `#{webhook.status_path}`" if webhook.status_path
            lines << "- Provider operation ID path: `#{webhook.provider_operation_id_path}`" if webhook.provider_operation_id_path
            lines << "- External ID path: `#{webhook.external_id_path}`" if webhook.external_id_path
            lines << "- Error path: `#{webhook.error_path}`" if webhook.error_path
            lines << "- Signature header: `#{webhook.signature_header}`" if webhook.signature_header
            lines << "- Signature algorithm: `#{webhook.signature_algorithm}`" if webhook.signature_algorithm
            lines << "- Signature encoding: `#{webhook.signature_encoding}`" if webhook.signature_encoding
            lines << "- Signed payload: `#{webhook.signed_payload}`" if webhook.signed_payload
            lines << "- Decision: #{decision_label(webhook.decision)}"
            if webhook.signed?
              lines << ""
              lines << "`process_callback(payload)` receives parsed JSON; webhook signature verification requires an unavailable host API for the raw body and signature header."
            end
          else
            lines << "No webhook mapping."
          end
        end
      end

      def render_gateway(lines, metadata)
        section(lines, "ProviderGateway config") do
          lines << "Requires manual/platform configuration."
          lines << ""
          lines << "- external_method: #{metadata["external_method"] || metadata[:external_method] || 'TODO'}"
          lines << "- gateway: #{metadata["gateway"] || metadata[:gateway] || 'TODO'}"
        end
      end

      def render_assumptions(lines, plan, provider_spec)
        section(lines, "Assumptions / Manual decisions / Review notes") do
          notes = []
          manual = plan.operations.values.select(&:manual?) + plan.fields.select(&:manual?)
          manual << plan.statuses if plan.statuses&.manual?
          manual << plan.security if plan.security&.manual?
          manual << plan.webhook if plan.webhook&.manual?
          notes << "#{manual.size} mapping decision(s) were confirmed manually." unless manual.empty?
          plan.diagnostics.each do |diagnostic|
            notes << "`#{diagnostic.code}` (#{diagnostic.state || diagnostic.severity}): #{diagnostic.message}"
          end
          unbound_headers = request_headers_without_mapping(plan, provider_spec)
          unless unbound_headers.empty?
            notes << "Unbound request headers require manual policy: #{unbound_headers.map { |name| "`#{name}`" }.join(', ')}."
          end
          notes << "Webhook runtime access remains a host integration responsibility." if plan.webhook&.signed?
          unknown = Array(plan.metadata["unknown_requisites"] || plan.metadata[:unknown_requisites])
          unless unknown.empty?
            notes << "Unknown requisite fields require explicit manual mapping/TODO: #{unknown.map { |item| unknown_requisite_label(item, code: false) }.join(', ')}."
          end
          notes = ["No review notes."] if notes.empty?
          notes.each { |note| lines << "- #{note}" }
        end
      end

      def request_headers_without_mapping(plan, _provider_spec)
        mapped_paths = plan.fields.select(&:request?).map(&:provider_path)
        mapped_headers = Array(plan.metadata["request_headers"] || plan.metadata[:request_headers]).filter_map do |item|
          value = stringify(item)
          value["provider_name"] if value["operation_role"].to_s == "create_request"
        end
        security_name = plan.security&.name
        signature_name = plan.webhook&.signature_header
        plan.operations.values.flat_map do |mapping|
          mapping.operation.parameters.select(&:header?).map(&:name)
        end.uniq.reject do |name|
          mapped_paths.any? { |path| path.casecmp?(name) } ||
            mapped_headers.any? { |header| header.to_s.casecmp?(name.to_s) } ||
            name.to_s.casecmp?(security_name.to_s) ||
            name.to_s.casecmp?(signature_name.to_s)
        end
      end

      def section(lines, title)
        lines << "## #{title}"
        lines << ""
        yield
        lines << ""
      end

      def decision_label(value)
        case value.to_s
        when "auto" then "automatic"
        when "needs_review" then "needs review"
        when "manual" then "manual"
        else value.to_s
        end
      end

      def description_suffix(description)
        description.nil? || description.empty? ? "" : " — #{description}"
      end

      def unknown_requisite_label(item, code: true)
        value = stringify(item)
        if value.is_a?(Hash)
          path = value["provider_path"]
          label = "#{path} (required=#{value["required"] == true})"
        else
          label = value.to_s
        end
        code ? "`#{label}`" : label
      end

      def stable_inspect(value)
        case value
        when Hash
          pairs = value.sort_by { |key, _| key.to_s }.map do |key, item|
            "#{stable_inspect(key)}=>#{stable_inspect(item)}"
          end
          "{#{pairs.join(', ')}}"
        when Array
          "[#{value.map { |item| stable_inspect(item) }.join(', ')}]"
        else
          value.inspect
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
    end
  end
end
