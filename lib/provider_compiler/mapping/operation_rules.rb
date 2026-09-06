# frozen_string_literal: true

require_relative "../core/space_payments_contract"

module ProviderCompiler
  module Mapping
    class OperationRules
      CREATE_ACTIONS = %w[create new initiate start send создать создание].freeze
      PAYMENT_WORDS = %w[payout payouts withdraw withdrawal transfer transfers payment payments выплат перевод].freeze
      FETCH_ACTIONS = %w[get fetch find retrieve lookup status state получить проверить статус].freeze
      CALLBACK_WORDS = %w[webhook callback notification notifications notify event вебхук колбэк уведомление событие].freeze
      NEGATIVE_CREATE = %w[cancel balance status webhook callback notification refund отмен баланс статус уведомление возврат].freeze
      NEGATIVE_FETCH = %w[create cancel balance webhook callback notification создать отмен баланс уведомление].freeze
      NEGATIVE_CALLBACK = %w[balance create cancel fetch retrieve lookup status баланс создать отмен получить].freeze

      def score(operation, role)
        role = role.to_s
        unless ProviderCompiler::Core::SpacePaymentsContract.operation_role?(role)
          raise ArgumentError, "unknown operation role: #{role.inspect}"
        end

        evidence = []
        send("score_#{role}", operation, evidence)
        { score: evidence.sum { |item| item["weight"] }, evidence: evidence }
      end

      private

      def score_create_request(operation, evidence)
        add_http(evidence, operation, "POST" => 15, "PUT" => 5, "PATCH" => 5, "GET" => -15, "DELETE" => -20)
        add_keyword(evidence, operation, CREATE_ACTIONS, 20, "create_action_keyword")
        add_keyword(evidence, operation, PAYMENT_WORDS, 15, "payment_semantic_keyword")
        add_keyword(evidence, operation, NEGATIVE_CREATE, -30, "create_negative_keyword")

        schema = operation.request_body&.schema
        add(evidence, "request_amount_shape", 10, "request body contains an amount-like field") if schema_has?(schema, %w[amount sum total value payment_amount payout_amount])
        add(evidence, "request_recipient_shape", 10, "request body contains a recipient-like field") if schema_has?(schema, %w[recipient requisite requisites destination payee beneficiary receiver])
        add(evidence, "request_external_id_shape", 5, "request body contains a merchant/client reference") if schema_has?(schema, %w[external_id merchant_id client_id order_id request_id reference_id reference external_reference])
        add(evidence, "response_provider_id_shape", 5, "success response contains an id field") if success_schema_has?(operation, %w[id payout_id payment_id transaction_id transfer_id])
        add(evidence, "response_status_shape", 10, "success response contains status/state") if success_schema_has?(operation, %w[status state])
      end

      def score_fetch_status(operation, evidence)
        add_http(evidence, operation, "GET" => 15, "POST" => 2, "PUT" => 1, "PATCH" => 1)
        add_keyword(evidence, operation, FETCH_ACTIONS, 20, "fetch_status_keyword")
        add_keyword(evidence, operation, PAYMENT_WORDS, 10, "fetch_payment_semantic")
        add_keyword(evidence, operation, NEGATIVE_FETCH, -30, "fetch_negative_keyword")
        if operation.parameters.any? { |parameter| parameter.path? && id_like?(parameter.name) }
          add(evidence, "status_path_id_parameter", 10, "operation has an id-like path parameter")
        end
        add(evidence, "status_response_shape", 20, "success response contains status/state") if success_schema_has?(operation, %w[status state])
        add(evidence, "status_response_id_shape", 5, "success response contains a provider id") if success_schema_has?(operation, %w[id payout_id payment_id transaction_id transfer_id])
      end

      def score_process_callback(operation, evidence)
        add_http(evidence, operation, "POST" => 10, "PUT" => 3, "PATCH" => 3, "GET" => -10)
        add_keyword(evidence, operation, CALLBACK_WORDS, 35, "callback_keyword")
        add_keyword(evidence, operation, NEGATIVE_CALLBACK, -20, "callback_negative_keyword")
        schema = operation.request_body&.schema
        add(evidence, "callback_event_shape", 12, "callback body contains event/type") if schema_has?(schema, %w[event event_type])
        add(evidence, "callback_status_shape", 12, "callback body contains status/state") if schema_has?(schema, %w[status state])
        add(evidence, "callback_id_shape", 8, "callback body contains an operation id") if schema_has?(schema, %w[payout_id payment_id transaction_id transfer_id operation_id id])
        if operation.parameters.any? { |parameter| parameter.header? && signature_text?(parameter) }
          add(evidence, "callback_signature_header", 10, "operation has a signature/HMAC header")
        end
      end

      def add_http(evidence, operation, weights)
        weight = weights[operation.http_method.to_s.upcase]
        add(evidence, "http_#{operation.http_method.to_s.downcase}", weight, "HTTP method is #{operation.http_method}") if weight
      end

      def add_keyword(evidence, operation, keywords, weight, rule)
        matched = tokens(operation) & keywords
        add(evidence, rule, weight, "matched keywords: #{matched.join(', ')}") unless matched.empty?
      end

      def add(evidence, rule, weight, reason)
        evidence << { "rule" => rule, "weight" => weight, "reason" => reason }
      end

      def tokens(operation)
        values = [operation.path, operation.operation_id, *operation.tags, operation.summary, operation.description]
        values.compact.flat_map do |value|
          value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1 \\2').downcase.scan(/[[:alnum:]]+/)
        end.uniq
      end

      def schema_has?(schema, aliases)
        return false unless schema

        schema.properties.any? do |name, child|
          aliases.include?(normalize(name)) || schema_has?(child, aliases)
        end
      end

      def success_schema_has?(operation, aliases)
        operation.success_responses.values.any? { |response| schema_has?(response.schema, aliases) }
      end

      def id_like?(name)
        normalized = normalize(name)
        normalized == "id" || normalized.end_with?("_id")
      end

      def normalize(value)
        value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase.tr("- ", "__")
      end

      def signature_text?(parameter)
        [parameter.name, parameter.description].compact.join(" ").match?(/signature|\bsign\b|hmac|digest|подпис/i)
      end
    end
  end
end
