# frozen_string_literal: true

require_relative "../core/space_payments_contract"

module ProviderCompiler
  module Mapping
    class FieldRules
      PROVIDER_OPERATION_ID_ALIASES = %w[
        payout_id payment_id transaction_id transfer_id withdrawal_id withdraw_id order_id disbursement_id operation_id id
      ].freeze

      MERCHANT_REFERENCE_ALIASES = %w[
        merchant_reference merchant_reference_id client_reference client_reference_id external_id
        merchant_id client_id request_id reference_id external_reference
      ].freeze

      ALIASES = {
        "operation.amount" => %w[amount sum total value payment_amount payout_amount],
        "operation.id" => (MERCHANT_REFERENCE_ALIASES + %w[reference]).freeze,
        "operation.provider_operation_key" => (PROVIDER_OPERATION_ID_ALIASES + %w[provider_id]).freeze,
        "operation.payout_requisite" => %w[recipient requisite requisites destination payee beneficiary receiver account]
      }.freeze

      def score(candidate, internal_path)
        validate_internal_path!(internal_path)
        candidate = symbolize(candidate)
        evidence = []
        leaf = normalize(candidate[:path].to_s.split(".").last)
        full = normalize(candidate[:path])
        schema = candidate[:schema]

        case internal_path.to_s
        when "operation.amount"
          alias_score(evidence, leaf, full, ALIASES.fetch("operation.amount"), 45)
          add(evidence, "amount_numeric_type", 15, "field is numeric") if %w[integer number].include?(schema&.type.to_s.downcase)
          add(evidence, "amount_description", 15, "description contains monetary terminology") if schema&.description.to_s.match?(/amount|sum|сумм|копе|cent|minor unit/i)
          add(evidence, "request_source", 10, "field comes from request body") if candidate[:source] == "request_body"
        when "operation.id"
          alias_score(evidence, leaf, full, ALIASES.fetch("operation.id"), 45)
          if merchant_order_id?(leaf, schema) && candidate[:source] == "request_body"
            add(evidence, "merchant_order_id_context", 45, "request order id is described as merchant/client identity")
          end
          add(evidence, "weak_plain_request_id", 15, "plain request id is ambiguous") if leaf == "id"
          add(evidence, "client_id_description", 15, "description identifies merchant/client reference") if schema&.description.to_s.match?(/merchant|client|external|order|reference|мерчант|клиент|внешн/i)
          add(evidence, "request_source", 15, "field is sent in request") if candidate[:source] == "request_body"
          add(evidence, "string_identifier", 5, "identifier is a string") if schema&.type.to_s.casecmp?("string")
        when "operation.provider_operation_key"
          provider_id_alias_score(evidence, leaf, full, candidate, schema)
          add(evidence, "response_provider_id", 20, "identifier comes from provider success response") if candidate[:source] == "response"
          add(evidence, "status_path_parameter", 20, "identifier is a status-operation path parameter") if candidate[:source] == "parameter" && candidate[:location].to_s.casecmp?("path")
          add(evidence, "string_identifier", 5, "identifier is a string") if schema&.type.to_s.casecmp?("string")
        when "operation.payout_requisite"
          alias_score(evidence, leaf, full, ALIASES.fetch("operation.payout_requisite"), 45)
          add(evidence, "requisite_object_type", 20, "recipient/requisite candidate is an object") if schema&.object?
          add(evidence, "recipient_description", 15, "description identifies recipient/requisites") if schema&.description.to_s.match?(/recipient|requisite|beneficiary|receiver|получател|реквизит/i)
          add(evidence, "request_source", 10, "field comes from request body") if candidate[:source] == "request_body"
        end

        { score: evidence.sum { |item| item["weight"] }, evidence: evidence }
      end

      private

      def validate_internal_path!(path)
        unless ProviderCompiler::Core::SpacePaymentsContract.known_operation_path?(path)
          raise ArgumentError, "unknown internal field: #{path.inspect}"
        end
      end

      def alias_score(evidence, leaf, full, aliases, weight)
        return unless aliases.include?(leaf) || aliases.include?(full)

        add(evidence, "field_alias_match", weight, "provider field matches a known alias")
      end

      def merchant_order_id?(leaf, schema)
        %w[order_id merchant_order_id].include?(leaf) &&
          schema&.description.to_s.match?(/merchant|client|external|мерчант|клиент|внешн/i)
      end

      def provider_id_alias_score(evidence, leaf, full, candidate, schema)
        aliases = ALIASES.fetch("operation.provider_operation_key")
        return unless aliases.include?(leaf) || aliases.include?(full)
        return if leaf == "order_id" && !provider_order_context?(candidate, schema)

        weight = leaf == "id" ? 35 : 45
        add(evidence, "field_alias_match", weight, "provider field matches a known alias")
      end

      def provider_order_context?(candidate, schema)
        description = [candidate[:description], schema&.description].compact.join(" ")
        %w[response parameter].include?(candidate[:source].to_s) &&
          description.match?(/provider|generated|payout|disbursement|провайдер/i)
      end

      def add(evidence, rule, weight, reason)
        evidence << { "rule" => rule, "weight" => weight, "reason" => reason }
      end

      def normalize(value)
        value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase.tr("-. ", "___")
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
      end
    end
  end
end
