# frozen_string_literal: true

require_relative "url_builder"
require_relative "../core/diagnostic"
require_relative "../core/space_payments_contract"
require_relative "../core/nested_path"

module ProviderCompiler
  module Generation
    class ServiceRenderer
      attr_reader :diagnostics

      def initialize(url_builder: UrlBuilder.new)
        @url_builder = url_builder
        @diagnostics = []
      end

      def render(mapping_plan:, class_name:)
        @diagnostics = []
        validate_required_mappings(mapping_plan)

        lines = ["# frozen_string_literal: true", ""]
        lines << 'require "base64"' if mapping_plan.security&.basic?
        lines << "" if mapping_plan.security&.basic?
        lines << "class Provider::#{class_name} < Provider::BaseService"
        lines.concat(render_connection(mapping_plan, class_name))
        lines.concat(render_status_map(mapping_plan))
        lines.concat(render_webhook_signature(mapping_plan.webhook))
        lines.concat(render_check_conditions(mapping_plan))
        lines.concat(render_create_request(mapping_plan))
        lines.concat(render_process_callback(mapping_plan))
        lines.concat(render_fetch_status(mapping_plan))
        lines << "  private"
        lines << ""
        lines.concat(render_variant_selector(mapping_plan))
        lines.concat(render_error_handlers(mapping_plan))
        lines.concat(render_helpers(mapping_plan))
        lines << "end"
        lines << ""
        lines.join("\n")
      end

      private

      def validate_required_mappings(plan)
        %w[create_request fetch_status process_callback].each do |role|
          next if plan.operation(role)

          add_error(:generation_mapping_missing, "Operation mapping #{role} is missing", role)
        end
        add_error(:generation_mapping_missing, "Status mapping is missing", "statuses") unless plan.statuses
        add_error(:generation_mapping_missing, "Webhook mapping is missing", "webhook") unless plan.webhook
        if plan.security && (!plan.security.auto? && !plan.security.manual?)
          add_error(:security_mapping_unresolved, "Security mapping must be resolved before generation", "security")
        elsif plan.security && !(plan.security.api_key? || plan.security.bearer? || plan.security.basic?)
          add_error(:security_mapping_unresolved, "Security mapping type is unsupported", "security")
        end
      end

      def render_connection(plan, class_name)
        base_url = plan.metadata["base_url"] || plan.metadata[:base_url]
        return [] if base_url.nil? || base_url.to_s.empty?

        env_name = class_name.to_s.sub(/Service\z/, "")
                             .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
                             .gsub(/[^a-zA-Z0-9]+/, "_")
                             .upcase
        env_name = "PROVIDER" if env_name.empty?
        env_name = "#{env_name}_BASE_URL"
        [
          "  BASE_URL = ENV.fetch(#{env_name.inspect}, #{base_url.to_s.inspect}).sub(%r{/+\\z}, \"\").freeze",
          ""
        ]
      end

      def render_status_map(plan)
        mappings = plan.statuses&.mappings || {}
        lines = ["  STATUS_MAP = {"]
        mappings.sort_by { |provider, _| provider }.each_with_index do |(provider, internal), index|
          comma = index == mappings.size - 1 ? "" : ","
          lines << "    #{provider.inspect} => #{internal.inspect}#{comma}"
        end
        lines << "  }.freeze"
        lines << ""
        lines
      end

      def render_webhook_signature(webhook)
        return [] unless webhook&.signed?

        value = {
          "header" => webhook.signature_header,
          "algorithm" => webhook.signature_algorithm,
          "encoding" => webhook.signature_encoding,
          "signed_payload" => webhook.signed_payload,
          "secret_credential_path" => webhook.secret_credential_path
        }
        ["  WEBHOOK_SIGNATURE = #{ruby_hash(value)}.freeze", ""]
      end

      def render_check_conditions(plan)
        lines = ["  def check_conditions(operation, request_method = nil)"]
        variants = request_variants(plan)
        unless variants.empty?
          lines << "    selected_variant = request_variant(operation)"
          lines << "    return failure(:bad_request, \"provider_compiler.errors.unsupported_payout_requisite\") unless selected_variant"
        end
        if plan.conditions.empty?
          lines << "    success"
        else
          plan.conditions.each_with_index do |condition, index|
            condition = stringify(condition)
            expression = expression_for_provider_path(
              plan,
              condition["provider_path"],
              transform: true,
              source: condition["source"],
              location: condition["location"]
            )
            unless expression
              if variant_condition_covered?(plan, condition["provider_path"]) ||
                 descendant_request_path_covered?(plan, condition)
                lines << "    # Condition #{condition["provider_path"].inspect} is enforced by request variant selection."
                next
              end

              lines << "    # TODO: Provider condition #{condition["provider_path"].inspect} has no mapped operation field."
              add_warning(
                :condition_runtime_value_missing,
                "Condition cannot be rendered without a mapped operation field",
                condition["provider_path"]
              )
              next
            end

            variable = "condition_value_#{index + 1}"
            lines << "    #{variable} = #{expression}"
            guards = condition_guard(variable, condition)
            variant = variant_for_provider_path(plan, condition["provider_path"])
            if variant
              lines << "    if selected_variant == #{variant['name'].inspect}"
              lines.concat(guards.map { |line| "      #{line}" })
              lines << "    end"
            else
              lines.concat(guards.map { |line| "    #{line}" })
            end
          end
          lines << "    success"
        end
        lines << "  end"
        lines << ""
        lines
      end

      def condition_guard(variable, condition)
        path = condition["provider_path"]
        kind = condition["kind"] || ("required_if" if condition.key?("required_if"))
        value = condition["value"]
        failure = "failure(:bad_request, \"provider_compiler.conditions.failed\", field: #{path.inspect}, kind: #{kind.inspect})"
        case kind
        when "required"
          ["return #{failure} if #{variable}.nil?"]
        when "minimum"
          ["return #{failure} if !#{variable}.nil? && #{variable} < #{value.inspect}"]
        when "maximum"
          ["return #{failure} if !#{variable}.nil? && #{variable} > #{value.inspect}"]
        when "enum"
          ["return #{failure} if !#{variable}.nil? && !#{Array(value).inspect}.include?(#{variable})"]
        when "pattern"
          ["return #{failure} if !#{variable}.nil? && !Regexp.new(#{value.to_s.inspect}).match?(#{variable}.to_s)"]
        when "min_length"
          ["return #{failure} if !#{variable}.nil? && #{variable}.length < #{value.inspect}"]
        when "max_length"
          ["return #{failure} if !#{variable}.nil? && #{variable}.length > #{value.inspect}"]
        when "required_if"
          render_required_if(variable, condition, failure)
        else
          add_warning(:condition_kind_unsupported, "Unsupported condition kind #{kind}", path)
          ["# TODO: Unsupported condition kind #{kind.inspect} for #{path.inspect}."]
        end
      end

      def render_required_if(variable, condition, failure)
        rule = stringify(condition["required_if"] || {})
        if rule["internal_path"] && rule["present"] == true
          reference = internal_expression(rule["internal_path"])
          return ["return #{failure} if !#{reference}.nil? && #{variable}.nil?"]
        end

        reference = expression_for_provider_path(@current_plan, rule["path"], transform: false)
        unless reference && rule.key?("equals")
          add_warning(:condition_kind_unsupported, "Incomplete required_if condition", condition["provider_path"])
          return ["# TODO: Incomplete required_if condition for #{condition["provider_path"].inspect}."]
        end

        ["return #{failure} if #{reference} == #{rule["equals"].inspect} && #{variable}.nil?"]
      end

      def render_create_request(plan)
        mapping = plan.operation("create_request")
        return render_missing_method("create_request", "operation") unless mapping

        @current_plan = plan
        url = url_expression(mapping, plan.fields)
        fields = request_fields(plan, "create_request", "request_body")
        base_fields = fields.reject { |field| request_variant(field) }
        body = nested_expression(base_fields, constants: request_constants_hash(plan))
        query = query_security?(plan.security) || mapped_query_parameters?(plan, "create_request")
        lines = ["  def create_request(operation, request_method = nil, *args, **kwargs)"]
        lines << "    url = #{effective_url_expression(url, plan)}"
        lines.concat(render_security(plan.security, indent: 4, query: query))
        lines.concat(render_operation_parameters(plan, "create_request", indent: 4))
        lines.concat(render_operation_parameter_constants(plan, "create_request", indent: 4))
        lines.concat(render_request_headers(plan, indent: 4))
        lines.concat(render_multiline_assignment("body", body, 4))
        lines.concat(render_request_variants(plan, fields))
        lines << render_client_call(mapping.operation.http_method, body: true, query: query, indent: 4)
        lines << "    return handle_create_request_error(response) unless response_success?(response)"
        lines << ""
        lines << "    payload = response_body(response)"
        response_id = plan.fields.find do |field|
          field.response? && field.internal_path == "operation.provider_operation_key" &&
            operation_role(field) == "create_request"
        end
        if response_id
          lines << "    provider_id = dig_value(payload, #{response_id.provider_path.inspect})"
          lines << "    return failure(:internal_server_error, \"provider_compiler.errors.provider_operation_key_missing\") if provider_id.nil? || provider_id.to_s.empty?"
          lines << "    success(result: { id: provider_id })"
        else
          add_error(:response_field_mapping_missing, "Create response provider id mapping is missing", "create_request")
          lines << "    failure(:internal_server_error, \"provider_compiler.errors.provider_operation_key_missing\")"
        end
        lines << "  end"
        lines << ""
        lines
      end

      def render_process_callback(plan)
        webhook = plan.webhook
        return render_missing_method("process_callback", "payload") unless webhook

        lines = ["  def process_callback(payload)"]
        if webhook.signed?
          lines << "    # TODO: Webhook signature verification requires host runtime access to raw body and signature header."
        end
        lines << "    provider_id = dig_value(payload, #{webhook.provider_operation_id_path.inspect})"
        lines << "    return failure(:unprocessable_entity, \"provider_compiler.errors.provider_operation_key_missing\") if provider_id.nil? || provider_id.to_s.empty?"
        lines << "    provider_status = dig_value(payload, #{webhook.status_path.inspect})"
        lines << "    event = dig_value(payload, #{webhook.event_path.inspect})" if webhook.event_path
        lines << "    provider_error = dig_value(payload, #{webhook.error_path.inspect})" if webhook.error_path
        lines << "    internal_status = STATUS_MAP[provider_status.to_s]"
        lines << "    return failure(:unprocessable_entity, \"provider_compiler.errors.unknown_provider_status\", provider_status: provider_status) unless internal_status"
        lines << ""
        lines << "    case internal_status"
        lines << "    when \"approved\""
        lines << "      approve_operation(provider_id)"
        lines << "    when \"rejected\""
        reject_args = webhook.error_path ? ", error: provider_error" : ""
        lines << "      reject_operation(provider_id#{reject_args})"
        lines << "    else"
        lines << "      success"
        lines << "    end"
        lines << "  end"
        lines << ""
        lines
      end

      def render_fetch_status(plan)
        mapping = plan.operation("fetch_status")
        return render_missing_method("fetch_status", "operation") unless mapping

        url = url_expression(mapping, plan.fields)
        status_path = plan.statuses&.provider_path("fetch_status") || plan.webhook&.status_path
        add_error(:status_path_missing, "Fetch-status provider path is missing from MappingPlan", "fetch_status") unless status_path
        query = query_security?(plan.security) || mapped_query_parameters?(plan, "fetch_status")
        lines = ["  def fetch_status(operation)"]
        lines << "    return failure(:bad_request, \"provider_compiler.errors.provider_operation_key_missing\") if operation.provider_operation_key.nil? || operation.provider_operation_key.to_s.empty?"
        lines << "    url = #{effective_url_expression(url, plan)}"
        lines.concat(render_security(plan.security, indent: 4, query: query))
        lines.concat(render_operation_parameters(plan, "fetch_status", indent: 4))
        lines.concat(render_operation_parameter_constants(plan, "fetch_status", indent: 4))
        lines << render_client_call(mapping.operation.http_method, body: false, query: query, indent: 4)
        lines << "    return handle_fetch_status_error(response) unless response_success?(response)"
        lines << ""
        lines << "    payload = response_body(response)"
        lines << "    provider_status = dig_value(payload, #{status_path.inspect})"
        lines << "    internal_status = STATUS_MAP[provider_status.to_s]"
        lines << "    return failure(:unprocessable_entity, \"provider_compiler.errors.unknown_provider_status\", provider_status: provider_status) unless internal_status"
        lines << ""
        lines << "    case internal_status"
        lines << "    when \"approved\""
        lines << "      approve_operation(operation)"
        lines << "    when \"rejected\""
        lines << "      reject_operation(operation)"
        lines << "    else"
        lines << "      success"
        lines << "    end"
        lines << "  end"
        lines << ""
        lines
      end

      def render_security(security, indent:, query: false)
        prefix = " " * indent
        lines = ["#{prefix}headers = {}"]
        lines << "#{prefix}query = {}" if query
        return lines unless security

        credential = "read_value(credentials, #{security.credential_path.to_s.inspect})"
        if security.api_key? && security.header?
          lines << "#{prefix}headers[#{security.name.inspect}] = #{credential}"
        elsif security.api_key? && security.query?
          lines << "#{prefix}query[#{security.name.inspect}] = #{credential}"
        elsif security.api_key? && security.cookie?
          lines << %Q{#{prefix}headers["Cookie"] = [headers["Cookie"], [#{security.name.inspect}, #{credential}].join("=")].compact.reject(&:empty?).join("; ")}
        elsif security.bearer?
          lines << "#{prefix}headers[#{security.name.inspect}] = [#{security.prefix.inspect}, #{credential}].join(\" \")"
        elsif security.basic?
          username = security.parameters["username_path"]
          password = security.parameters["password_path"]
          lines << "#{prefix}headers[#{security.name.inspect}] = basic_auth_value("
          lines << "#{prefix}  read_value(credentials, #{username.to_s.inspect}),"
          lines << "#{prefix}  read_value(credentials, #{password.to_s.inspect})"
          lines << "#{prefix})"
        end
        lines
      end

      def render_client_call(method, body:, query:, indent:)
        normalized = method.to_s.downcase
        unless normalized.match?(/\A[a-z]+\z/)
          add_error(:unsafe_http_method, "HTTP method is not safe to render", method)
          normalized = "public_send"
        end
        arguments = ["url", "headers: headers"]
        arguments << "body: body" if body
        arguments << "query: query" if query
        "#{' ' * indent}response = client.#{normalized}(#{arguments.join(', ')})"
      end

      def render_error_handlers(plan)
        %w[create_request fetch_status].flat_map do |role|
          mappings = plan.errors.select { |mapping| mapping.operation_role == role }
          render_error_handler(role, mappings)
        end
      end

      def render_error_handler(role, mappings)
        method_name = "handle_#{role}_error"
        if mappings.empty?
          return [
            "  def #{method_name}(response)",
            "    failure(:internal_server_error, \"provider_compiler.errors.unexpected_http_status\", http_status: response_status(response))",
            "  end",
            ""
          ]
        end

        lines = ["  def #{method_name}(response)", "    status = response_status(response)", "", "    case status"]
        mappings.sort_by { |mapping| mapping.http_status.to_i }.each do |mapping|
          lines << "    when #{mapping.http_status.to_i}"
          lines.concat(render_error_mapping(mapping, indent: 6))
        end
        lines << "    else"
        lines << "      failure(:internal_server_error, \"provider_compiler.errors.unexpected_http_status\", http_status: status)"
        lines << "    end"
        lines << "  end"
        lines << ""
        lines
      end

      def render_error_mapping(mapping, indent:)
        prefix = " " * indent
        code_path = mapping.provider_code_path
        targets = stringify(mapping.metadata["provider_code_targets"] || {}).reject do |_provider_code, target|
          target.to_s == mapping.target.to_s
        end
        lines = []
        if code_path && !targets.empty?
          lines << "#{prefix}provider_code = dig_value(response_body(response), #{code_path.inspect})"
          lines << "#{prefix}case provider_code.to_s"
          targets.sort.each do |provider_code, target|
            lines << "#{prefix}when #{provider_code.inspect}"
            lines << "#{prefix}  #{failure_expression(mapping, target, provider_code: "provider_code")}"
          end
          lines << "#{prefix}else"
          lines << "#{prefix}  #{failure_expression(mapping, mapping.target, provider_code: "provider_code")}"
          lines << "#{prefix}end"
        else
          lines << "#{prefix}#{failure_expression(mapping, mapping.target)}"
        end
        lines
      end

      def failure_expression(mapping, target, provider_code: nil)
        code = safe_failure_code(target)
        arguments = [":#{code}", "\"provider_compiler.errors.#{code}\"", "http_status: status"]
        if mapping.provider_code_path
          expression = provider_code || "dig_value(response_body(response), #{mapping.provider_code_path.inspect})"
          arguments << "provider_code: #{expression}"
        end
        if mapping.message_path
          arguments << "provider_message: dig_value(response_body(response), #{mapping.message_path.inspect})"
        end
        if mapping.retry_after_header
          arguments << "retry_after: response_header(response, #{mapping.retry_after_header.inspect})"
        end
        "failure(#{arguments.join(', ')})"
      end

      def safe_failure_code(target)
        code = target.to_s
        return code if ProviderCompiler::Core::SpacePaymentsContract.failure_code?(code)

        add_error(:unsupported_failure_code, "Failure code is outside the Space Payments contract", target)
        "internal_server_error"
      end

      def render_helpers(plan)
        lines = [
          "  def response_success?(response)",
          "    response_status(response).between?(200, 299)",
          "  end",
          "",
          "  def response_status(response)",
          "    value = response.respond_to?(:status) ? response.status : read_value(response, \"status\")",
          "    value.to_i",
          "  end",
          "",
          "  def response_body(response)",
          "    response.respond_to?(:body) ? response.body : read_value(response, \"body\")",
          "  end",
          "",
          "  def response_header(response, name)",
          "    headers = response.respond_to?(:headers) ? response.headers : read_value(response, \"headers\")",
          "    return nil unless headers.respond_to?(:each)",
          "",
          "    pair = headers.find { |key, _value| key.to_s.casecmp?(name.to_s) }",
          "    pair&.last",
          "  end",
          "",
          "  def dig_value(value, path)",
          "    return value if path.nil? || path.empty?",
          "",
          "    path.split(\".\").reduce(value) { |memo, key| read_value(memo, key) }",
          "  end",
          "",
          "  def read_value(value, key)",
          "    if value.is_a?(Hash)",
          "      value.key?(key) ? value[key] : value[key.to_sym]",
          "    elsif value.respond_to?(key)",
          "      value.public_send(key)",
          "    end",
          "  end",
          "",
          "  def put_value(target, path, value)",
          "    keys = path.to_s.split(\".\").reject(&:empty?)",
          "    leaf = keys.pop",
          "    parent = keys.reduce(target) do |current, key|",
          "      existing = current[key]",
          "      raise ArgumentError, \"nested path parent is not an object\" if existing && !existing.is_a?(Hash)",
          "      current[key] ||= {}",
          "    end",
          "    parent[leaf] = value unless leaf.nil?",
          "    target",
          "  end"
        ]
        if plan.metadata["base_url"] || plan.metadata[:base_url]
          lines.concat([
            "",
            "  def build_url(path)",
            "    base = BASE_URL.to_s.sub(%r{/+\\z}, \"\")",
            "    suffix = path.to_s.sub(%r{\\A/+}, \"\")",
            '    return "/#{suffix}" if base.empty?',
            "    return base if suffix.empty?",
            "",
            '    "#{base}/#{suffix}"',
            "  end"
          ])
        end
        if plan.fields.any? { |field| field.transformation&.fetch("type", nil).to_s == "enum" }
          lines.concat([
            "",
            "  def map_enum(mapping, value, field)",
            "    return mapping[value.to_s] if mapping.key?(value.to_s)",
            "",
            '    raise ArgumentError, "Unknown enum value for #{field}: #{value.inspect}"',
            "  end"
          ])
        end
        if plan.security&.basic?
          lines.concat([
            "",
            "  def basic_auth_value(username, password)",
            '    "Basic #{Base64.strict_encode64([username, password].join(\':\'))}"',
            "  end"
          ])
        end
        lines << ""
        lines
      end

      def request_fields(plan, role, source)
        plan.fields.select do |field|
          field.request? && operation_role(field) == role &&
            (field.metadata["source"] || field.metadata[:source]).to_s == source &&
            usable_requisite_mapping?(field)
        end
      end

      def render_request_variants(plan, fields)
        variants = request_variants(plan)
        return [] if variants.empty?

        lines = ["    case request_variant(operation)"]
        variants.each do |variant|
          lines << "    when #{variant['name'].inspect}"
          variant_fields = fields.select { |field| request_variant(field) == variant["name"] }
          variant_fields.sort_by(&:provider_path).each do |field|
            expression = transformed_expression(field, internal_expression(field.internal_path))
            lines << "      put_value(body, #{field.provider_path.inspect}, #{expression})"
          end
          stringify(variant["constants"] || {}).sort.each do |path, value|
            lines << "      put_value(body, #{path.inspect}, #{value.inspect})"
          end
        end
        lines << "    else"
        lines << "      return failure(:bad_request, \"provider_compiler.errors.unsupported_payout_requisite\")"
        lines << "    end"
        lines
      end

      def nested_expression(fields, constants: {})
        tree = {}
        fields.sort_by(&:provider_path).each do |field|
          ProviderCompiler::Core::NestedPath.put(
            tree, field.provider_path,
            { "__expression__" => transformed_expression(field, internal_expression(field.internal_path)) }
          )
        end
        stringify(constants).sort.each do |path, value|
          ProviderCompiler::Core::NestedPath.put(tree, path, { "__expression__" => value.inspect })
        end
        render_expression_hash(tree, 0)
      end

      def render_expression_hash(hash, level)
        return "{}" if hash.empty?

        indent = "  " * level
        child_indent = "  " * (level + 1)
        entries = hash.sort_by { |key, _| key }.map do |key, value|
          rendered = if value.is_a?(Hash) && value.keys == ["__expression__"]
                       value["__expression__"]
                     else
                       render_expression_hash(value, level + 1)
                     end
          "#{child_indent}#{key.inspect} => #{rendered}"
        end
        "{\n#{entries.join(",\n")}\n#{indent}}"
      end

      def render_multiline_assignment(name, expression, indent)
        prefix = " " * indent
        parts = expression.split("\n", -1)
        ["#{prefix}#{name} = #{parts.first}"] + parts.drop(1).map { |part| "#{prefix}#{part}" }
      end

      def expression_for_provider_path(plan, provider_path, transform:, source: nil, location: nil)
        @current_plan = plan
        normalized_source = source.to_s
        normalized_location = location.to_s

        if normalized_source.empty? || normalized_source == "request_body"
          constant = request_constant(plan, provider_path)
          return constant["value"].inspect if constant
        end

        if normalized_source == "parameter"
          parameter_constant = request_parameter_constants(plan, "create_request").find do |mapping|
            mapping["provider_name"].to_s == provider_path.to_s &&
              (normalized_location.empty? || mapping["location"].to_s.casecmp?(normalized_location))
          end
          return parameter_constant["value"].inspect if parameter_constant

          request_header = Array(plan.metadata["request_headers"] || plan.metadata[:request_headers]).map { |item| stringify(item) }.find do |mapping|
            mapping["provider_name"].to_s == provider_path.to_s &&
              (normalized_location.empty? || normalized_location.casecmp?("header"))
          end
          return "operation.id.to_s" if request_header && request_header["source"].to_s == "operation.id"
        end

        candidates = plan.fields.select do |field|
          metadata = field.metadata
          field_source = (metadata["source"] || metadata[:source]).to_s
          field_location = (metadata["location"] || metadata[:location]).to_s
          field.request? && operation_role(field) == "create_request" &&
            usable_requisite_mapping?(field) &&
            (normalized_source.empty? || field_source == normalized_source) &&
            (normalized_location.empty? || field_location.casecmp?(normalized_location)) &&
            (provider_path == field.provider_path || provider_path.to_s.start_with?("#{field.provider_path}."))
        end
        mapping = candidates.max_by { |field| field.provider_path.length }
        return unless mapping

        suffix = provider_path.to_s.delete_prefix(mapping.provider_path.to_s).delete_prefix(".")
        expression = internal_expression(mapping.internal_path)
        expression = "dig_value(#{expression}, #{suffix.inspect})" unless suffix.empty?
        transform && suffix.empty? ? transformed_expression(mapping, expression) : expression
      end

      def transformed_expression(mapping, expression)
        descriptor = mapping.transformation
        return expression unless descriptor.is_a?(Hash)

        descriptor = stringify(descriptor)
        case descriptor["type"]
        when "money"
          factor = descriptor["factor"]
          unless factor.is_a?(Integer)
            add_error(:transformation_incomplete, "Money transformation requires an integer factor", mapping.internal_path)
            return expression
          end
          "(#{expression}.nil? ? nil : #{expression} * #{factor})"
        when "enum"
          values = stringify(descriptor["mapping"] || {})
          "map_enum(#{ruby_hash(values)}, #{expression}, #{mapping.internal_path.inspect})"
        when "date_time"
          "(#{expression}.nil? ? nil : #{expression}.iso8601)"
        when "nested_object"
          expression
        when "type_cast"
          case descriptor["to"]
          when "string"
            "(#{expression}.nil? ? nil : #{expression}.to_s)"
          when "integer"
            "(#{expression}.nil? ? nil : Integer(#{expression}))"
          when "number"
            "(#{expression}.nil? ? nil : Float(#{expression}))"
          else
            add_error(:transformation_incomplete, "Type cast transformation has unsupported target", mapping.internal_path)
            expression
          end
        else
          add_error(:transformation_unsupported, "Unsupported transformation #{descriptor["type"]}", mapping.internal_path)
          expression
        end
      end

      def url_expression(mapping, fields)
        result = @url_builder.build(operation_mapping: mapping, field_mappings: fields)
        diagnostics.concat(result.diagnostics)
        result.value
      end

      def operation_role(field)
        (field.metadata["operation_role"] || field.metadata[:operation_role]).to_s
      end

      def request_variant(field)
        (field.metadata["request_variant"] || field.metadata[:request_variant])&.to_s
      end

      def usable_requisite_mapping?(field)
        return true unless field.internal_path.to_s.start_with?("operation.payout_requisite")

        field.auto? || field.manual?
      end

      def variant_for_provider_path(plan, provider_path)
        mapping = plan.fields.select do |field|
          field.request? && operation_role(field) == "create_request" && field.provider_path == provider_path
        end.first
        name = mapping && request_variant(mapping)
        return unless name

        Array(plan.metadata["request_variants"] || plan.metadata[:request_variants]).map { |item| stringify(item) }
          .find { |item| item["name"] == name }
      end

      def descendant_request_path_covered?(plan, condition)
        condition = stringify(condition)
        return false unless condition["source"].to_s == "request_body"
        return false unless condition["kind"].to_s == "required"

        prefix = "#{condition['provider_path']}."
        mapped = plan.fields.any? do |field|
          metadata = field.metadata
          field.request? && operation_role(field) == "create_request" &&
            (metadata["source"] || metadata[:source]).to_s == "request_body" &&
            usable_requisite_mapping?(field) && field.provider_path.to_s.start_with?(prefix)
        end
        constants = request_constants(plan).any? { |mapping| mapping["provider_path"].to_s.start_with?(prefix) }
        variant_constants = request_variants(plan).any? do |variant|
          stringify(variant["constants"] || {}).keys.any? { |path| path.to_s.start_with?(prefix) }
        end
        mapped || constants || variant_constants
      end

      def variant_condition_covered?(plan, provider_path)
        variants = Array(plan.metadata["request_variants"] || plan.metadata[:request_variants]).map { |item| stringify(item) }
        variants.any? do |variant|
          paths = variant.fetch("constants", {}).keys
          fields = plan.fields.select { |field| request_variant(field) == variant["name"] }.map(&:provider_path)
          (paths + fields).any? do |path|
            path == provider_path || path.start_with?("#{provider_path}.")
          end
        end
      end

      def variant_predicate(variant)
        condition = stringify(variant["when"] || {})
        expression = internal_expression(condition["path"])
        condition["present"] == true ? "!#{expression}.nil?" : expression
      end

      def request_variants(plan)
        Array(plan.metadata["request_variants"] || plan.metadata[:request_variants]).map { |item| stringify(item) }
      end

      def effective_url_expression(path_expression, plan)
        expression = path_expression || "nil"
        base_url = plan.metadata["base_url"] || plan.metadata[:base_url]
        base_url.nil? || base_url.to_s.empty? ? expression : "build_url(#{expression})"
      end

      def mapped_operation_parameters(plan, role)
        plan.fields.select do |field|
          metadata = field.metadata
          field.request? &&
            (metadata["operation_role"] || metadata[:operation_role]).to_s == role.to_s &&
            (metadata["source"] || metadata[:source]).to_s == "parameter"
        end
      end

      def mapped_query_parameters?(plan, role)
        mapped = mapped_operation_parameters(plan, role).any? do |field|
          (field.metadata["location"] || field.metadata[:location]).to_s.casecmp?("query")
        end
        mapped || request_parameter_constants(plan, role).any? { |mapping| mapping["location"].to_s.casecmp?("query") }
      end

      def render_operation_parameters(plan, role, indent:)
        prefix = " " * indent
        mapped_operation_parameters(plan, role).sort_by(&:provider_path).filter_map do |field|
          location = (field.metadata["location"] || field.metadata[:location]).to_s.downcase
          next if location == "path"

          expression = transformed_expression(field, internal_expression(field.internal_path))
          case location
          when "query"
            "#{prefix}query[#{field.provider_path.inspect}] = #{expression}"
          when "header"
            "#{prefix}headers[#{field.provider_path.inspect}] = #{expression}"
          when "cookie"
            %Q{#{prefix}headers["Cookie"] = [headers["Cookie"], [#{field.provider_path.inspect}, #{expression}].join("=")].compact.reject(&:empty?).join("; ")}
          else
            add_error(:parameter_location_unsupported, "Mapped request parameter location is unsupported", field.provider_path)
            nil
          end
        end
      end

      def request_parameter_constants(plan, role = nil)
        Array(plan.metadata["request_parameter_constants"] || plan.metadata[:request_parameter_constants]).map do |item|
          stringify(item)
        end.select do |mapping|
          role.nil? || mapping["operation_role"].to_s == role.to_s
        end
      end

      def render_operation_parameter_constants(plan, role, indent:)
        prefix = " " * indent
        request_parameter_constants(plan, role).sort_by { |mapping| [mapping["location"].to_s, mapping["provider_name"].to_s] }.filter_map do |mapping|
          name = mapping["provider_name"].to_s
          value = mapping["value"].inspect
          case mapping["location"].to_s.downcase
          when "query"
            "#{prefix}query[#{name.inspect}] = #{value}"
          when "header"
            "#{prefix}headers[#{name.inspect}] = #{value}"
          when "cookie"
            %Q{#{prefix}headers["Cookie"] = [headers["Cookie"], [#{name.inspect}, #{value}].join("=")].compact.reject(&:empty?).join("; ")}
          else
            add_error(:parameter_location_unsupported, "Constant request parameter location is unsupported", name)
            nil
          end
        end
      end

      def request_constants(plan)
        Array(plan.metadata["request_constants"] || plan.metadata[:request_constants]).map { |item| stringify(item) }
      end

      def request_constant(plan, provider_path)
        request_constants(plan).find do |mapping|
          mapping["operation_role"].to_s == "create_request" && mapping["provider_path"].to_s == provider_path.to_s
        end
      end

      def request_constants_hash(plan)
        request_constants(plan).each_with_object({}) do |mapping, result|
          next unless mapping["operation_role"].to_s == "create_request"

          result[mapping["provider_path"].to_s] = mapping["value"]
        end
      end

      def render_request_headers(plan, indent:)
        prefix = " " * indent
        Array(plan.metadata["request_headers"] || plan.metadata[:request_headers]).filter_map do |raw_mapping|
          mapping = stringify(raw_mapping)
          next unless mapping["operation_role"] == "create_request" && mapping["source"] == "operation.id"

          "#{prefix}headers[#{mapping['provider_name'].inspect}] = operation.id.to_s"
        end
      end

      def render_variant_selector(plan)
        variants = request_variants(plan)
        return [] if variants.empty?

        lines = ["  def request_variant(operation)"]
        variants.each do |variant|
          lines << "    return #{variant['name'].inspect} if #{variant_predicate(variant)}"
        end
        lines << "    nil"
        lines << "  end"
        lines << ""
        lines
      end

      def internal_expression(path)
        value = path.to_s
        tokens = value.split(".")
        return value unless tokens.first == "operation" && tokens.length > 2

        root = tokens.shift(2).join(".")
        "dig_value(#{root}, #{tokens.join('.').inspect})"
      end

      def query_security?(security)
        security&.api_key? && security.query?
      end

      def render_missing_method(name, argument)
        [
          "  def #{name}(#{argument})",
          "    failure(:internal_server_error, \"provider_compiler.errors.generation_mapping_missing\", role: #{name.inspect})",
          "  end",
          ""
        ]
      end

      def ruby_hash(hash)
        "{" + hash.map { |key, value| "#{key.inspect} => #{value.inspect}" }.join(", ") + "}"
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

      def add_error(code, message, location)
        diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :generation,
          state: :unresolved,
          location: location.to_s
        )
      end

      def add_warning(code, message, location)
        diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: :warning,
          code: code,
          message: message,
          stage: :generation,
          state: :needs_review,
          location: location.to_s
        )
      end
    end
  end
end
