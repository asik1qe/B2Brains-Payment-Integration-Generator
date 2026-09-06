# frozen_string_literal: true

class Provider::NovaPayPayoutApiService < Provider::BaseService
  BASE_URL = ENV.fetch("NOVA_PAY_PAYOUT_API_BASE_URL", "https://api.sandbox.novapay.example/v1").sub(%r{/+\z}, "").freeze

  STATUS_MAP = {
    "cancelled" => "rejected",
    "completed" => "approved",
    "failed" => "rejected",
    "pending" => "in_progress",
    "processing" => "in_progress"
  }.freeze

  WEBHOOK_SIGNATURE = {"header" => "X-NovaPay-Signature", "algorithm" => "HMAC-SHA256", "encoding" => "hex", "signed_payload" => "raw_body", "secret_credential_path" => "webhook_secret"}.freeze

  def check_conditions(operation, request_method = nil)
    selected_variant = request_variant(operation)
    return failure(:bad_request, "provider_compiler.errors.unsupported_payout_requisite") unless selected_variant
    condition_value_1 = (operation.amount.nil? ? nil : operation.amount * 100)
    return failure(:bad_request, "provider_compiler.conditions.failed", field: "amount", kind: "required") if condition_value_1.nil?
    condition_value_2 = (operation.amount.nil? ? nil : operation.amount * 100)
    return failure(:bad_request, "provider_compiler.conditions.failed", field: "amount", kind: "minimum") if !condition_value_2.nil? && condition_value_2 < 100000
    condition_value_3 = "RUB"
    return failure(:bad_request, "provider_compiler.conditions.failed", field: "currency", kind: "required") if condition_value_3.nil?
    condition_value_4 = "RUB"
    return failure(:bad_request, "provider_compiler.conditions.failed", field: "currency", kind: "enum") if !condition_value_4.nil? && !["RUB"].include?(condition_value_4)
    condition_value_5 = (operation.id.nil? ? nil : operation.id.to_s)
    return failure(:bad_request, "provider_compiler.conditions.failed", field: "external_id", kind: "required") if condition_value_5.nil?
    condition_value_6 = (operation.id.nil? ? nil : operation.id.to_s)
    return failure(:bad_request, "provider_compiler.conditions.failed", field: "external_id", kind: "max_length") if !condition_value_6.nil? && condition_value_6.length > 64
    # Condition "recipient" is enforced by request variant selection.
    # Condition "recipient.type" is enforced by request variant selection.
    # Condition "recipient.type" is enforced by request variant selection.
    condition_value_10 = dig_value(operation.payout_requisite, "sbp.phone")
    if selected_variant == "sbp"
      return failure(:bad_request, "provider_compiler.conditions.failed", field: "recipient.phone", kind: "required") if condition_value_10.nil?
    end
    condition_value_11 = dig_value(operation.payout_requisite, "sbp.phone")
    if selected_variant == "sbp"
      return failure(:bad_request, "provider_compiler.conditions.failed", field: "recipient.phone", kind: "pattern") if !condition_value_11.nil? && !Regexp.new("^7\\d{10}$").match?(condition_value_11.to_s)
    end
    condition_value_12 = dig_value(operation.payout_requisite, "sbp.bank_code")
    if selected_variant == "sbp"
      return failure(:bad_request, "provider_compiler.conditions.failed", field: "recipient.bank_code", kind: "required_if") if !dig_value(operation.payout_requisite, "sbp").nil? && condition_value_12.nil?
    end
    condition_value_13 = dig_value(operation.payout_requisite, "card_number")
    if selected_variant == "card"
      return failure(:bad_request, "provider_compiler.conditions.failed", field: "recipient.card_number", kind: "required_if") if !dig_value(operation.payout_requisite, "card_number").nil? && condition_value_13.nil?
    end
    success
  end

  def create_request(operation, request_method = nil, *args, **kwargs)
    url = build_url("/payouts")
    headers = {}
    headers["X-API-Key"] = read_value(credentials, "api_key")
    headers["Idempotency-Key"] = operation.id.to_s
    body = {
      "amount" => (operation.amount.nil? ? nil : operation.amount * 100),
      "currency" => "RUB",
      "external_id" => (operation.id.nil? ? nil : operation.id.to_s)
    }
    case request_variant(operation)
    when "sbp"
      put_value(body, "recipient.bank_code", dig_value(operation.payout_requisite, "sbp.bank_code"))
      put_value(body, "recipient.bank_name", dig_value(operation.payout_requisite, "sbp.bank_name"))
      put_value(body, "recipient.phone", dig_value(operation.payout_requisite, "sbp.phone"))
      put_value(body, "recipient.type", "sbp")
    when "card"
      put_value(body, "recipient.card_number", dig_value(operation.payout_requisite, "card_number"))
      put_value(body, "recipient.type", "card")
    else
      return failure(:bad_request, "provider_compiler.errors.unsupported_payout_requisite")
    end
    response = client.post(url, headers: headers, body: body)
    return handle_create_request_error(response) unless response_success?(response)

    payload = response_body(response)
    provider_id = dig_value(payload, "id")
    return failure(:internal_server_error, "provider_compiler.errors.provider_operation_key_missing") if provider_id.nil? || provider_id.to_s.empty?
    success(result: { id: provider_id })
  end

  def process_callback(payload)
    # TODO: Webhook signature verification requires host runtime access to raw body and signature header.
    provider_id = dig_value(payload, "payout_id")
    return failure(:unprocessable_entity, "provider_compiler.errors.provider_operation_key_missing") if provider_id.nil? || provider_id.to_s.empty?
    provider_status = dig_value(payload, "status")
    event = dig_value(payload, "event")
    provider_error = dig_value(payload, "error")
    internal_status = STATUS_MAP[provider_status.to_s]
    return failure(:unprocessable_entity, "provider_compiler.errors.unknown_provider_status", provider_status: provider_status) unless internal_status

    case internal_status
    when "approved"
      approve_operation(provider_id)
    when "rejected"
      reject_operation(provider_id, error: provider_error)
    else
      success
    end
  end

  def fetch_status(operation)
    return failure(:bad_request, "provider_compiler.errors.provider_operation_key_missing") if operation.provider_operation_key.nil? || operation.provider_operation_key.to_s.empty?
    url = build_url("/payouts/#{operation.provider_operation_key}")
    headers = {}
    headers["X-API-Key"] = read_value(credentials, "api_key")
    response = client.get(url, headers: headers)
    return handle_fetch_status_error(response) unless response_success?(response)

    payload = response_body(response)
    provider_status = dig_value(payload, "status")
    internal_status = STATUS_MAP[provider_status.to_s]
    return failure(:unprocessable_entity, "provider_compiler.errors.unknown_provider_status", provider_status: provider_status) unless internal_status

    case internal_status
    when "approved"
      approve_operation(operation)
    when "rejected"
      reject_operation(operation)
    else
      success
    end
  end

  private

  def request_variant(operation)
    return "sbp" if !dig_value(operation.payout_requisite, "sbp").nil?
    return "card" if !dig_value(operation.payout_requisite, "card_number").nil?
    nil
  end

  def handle_create_request_error(response)
    status = response_status(response)

    case status
    when 400
      failure(:bad_request, "provider_compiler.errors.bad_request", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"))
    when 401
      failure(:unauthorized, "provider_compiler.errors.unauthorized", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"))
    when 402
      failure(:unprocessable_entity, "provider_compiler.errors.unprocessable_entity", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"))
    when 409
      failure(:unprocessable_entity, "provider_compiler.errors.unprocessable_entity", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"))
    when 422
      failure(:unprocessable_entity, "provider_compiler.errors.unprocessable_entity", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"))
    when 429
      failure(:too_many_requests, "provider_compiler.errors.too_many_requests", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"), retry_after: response_header(response, "Retry-After"))
    when 500
      failure(:internal_server_error, "provider_compiler.errors.internal_server_error", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"))
    else
      failure(:internal_server_error, "provider_compiler.errors.unexpected_http_status", http_status: status)
    end
  end

  def handle_fetch_status_error(response)
    status = response_status(response)

    case status
    when 401
      failure(:unauthorized, "provider_compiler.errors.unauthorized", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"))
    when 404
      failure(:unprocessable_entity, "provider_compiler.errors.unprocessable_entity", http_status: status, provider_code: dig_value(response_body(response), "error.code"), provider_message: dig_value(response_body(response), "error.message"))
    else
      failure(:internal_server_error, "provider_compiler.errors.unexpected_http_status", http_status: status)
    end
  end

  def response_success?(response)
    response_status(response).between?(200, 299)
  end

  def response_status(response)
    value = response.respond_to?(:status) ? response.status : read_value(response, "status")
    value.to_i
  end

  def response_body(response)
    response.respond_to?(:body) ? response.body : read_value(response, "body")
  end

  def response_header(response, name)
    headers = response.respond_to?(:headers) ? response.headers : read_value(response, "headers")
    return nil unless headers.respond_to?(:each)

    pair = headers.find { |key, _value| key.to_s.casecmp?(name.to_s) }
    pair&.last
  end

  def dig_value(value, path)
    return value if path.nil? || path.empty?

    path.split(".").reduce(value) { |memo, key| read_value(memo, key) }
  end

  def read_value(value, key)
    if value.is_a?(Hash)
      value.key?(key) ? value[key] : value[key.to_sym]
    elsif value.respond_to?(key)
      value.public_send(key)
    end
  end

  def put_value(target, path, value)
    keys = path.to_s.split(".").reject(&:empty?)
    leaf = keys.pop
    parent = keys.reduce(target) do |current, key|
      existing = current[key]
      raise ArgumentError, "nested path parent is not an object" if existing && !existing.is_a?(Hash)
      current[key] ||= {}
    end
    parent[leaf] = value unless leaf.nil?
    target
  end

  def build_url(path)
    base = BASE_URL.to_s.sub(%r{/+\z}, "")
    suffix = path.to_s.sub(%r{\A/+}, "")
    return "/#{suffix}" if base.empty?
    return base if suffix.empty?

    "#{base}/#{suffix}"
  end

end
