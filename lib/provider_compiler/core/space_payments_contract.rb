# frozen_string_literal: true

module ProviderCompiler
  module Core
    module SpacePaymentsContract
      REQUIRED_SERVICE_METHODS = %w[
        check_conditions
        create_request
        process_callback
        fetch_status
      ].freeze

      OPERATION_ROLES = %w[
        create_request
        fetch_status
        process_callback
      ].freeze

      INTERNAL_STATUSES = %w[
        in_progress
        approved
        rejected
      ].freeze

      FAILURE_CODES = %i[
        bad_request
        unauthorized
        forbidden
        unprocessable_entity
        too_many_requests
        internal_server_error
      ].freeze

      KNOWN_OPERATION_FIELDS = %w[
        amount
        id
        provider_operation_key
        payout_requisite
      ].freeze

      KNOWN_OPERATION_PATHS = %w[
        operation.amount
        operation.id
        operation.provider_operation_key
        operation.payout_requisite
        operation.payout_requisite.sbp.phone
        operation.payout_requisite.sbp.bank_code
        operation.payout_requisite.sbp.bank_name
        operation.payout_requisite.card_number
      ].freeze

      KNOWN_PROVIDER_ERRORS = %w[
        Provider::RateLimitError
        Provider::UnauthorizedError
      ].freeze

      module_function

      def required_service_method?(name)
        REQUIRED_SERVICE_METHODS.include?(name.to_s)
      end

      def operation_role?(name)
        OPERATION_ROLES.include?(name.to_s)
      end

      def internal_status?(status)
        INTERNAL_STATUSES.include?(status.to_s)
      end

      def failure_code?(code)
        FAILURE_CODES.include?(code.to_sym)
      rescue NoMethodError
        false
      end

      def known_operation_field?(name)
        KNOWN_OPERATION_FIELDS.include?(name.to_s)
      end

      def known_operation_path?(path)
        KNOWN_OPERATION_PATHS.include?(path.to_s)
      end

      def known_provider_error?(name)
        KNOWN_PROVIDER_ERRORS.include?(name.to_s)
      end
    end
  end
end
