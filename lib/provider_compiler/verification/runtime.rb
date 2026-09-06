# frozen_string_literal: true

require_relative "../core/diagnostic"
require_relative "../core/result"

module ProviderCompiler
  module Verification
    class Runtime
      HTTP_METHODS = %w[get post put patch delete head options trace].freeze

      class FakeCredentials
        ATTRIBUTES = %i[api_key token username password webhook_secret].freeze
        attr_reader(*ATTRIBUTES)

        def initialize(
          api_key: "test-api-key",
          token: "test-token",
          username: "test-username",
          password: "test-password",
          webhook_secret: "test-webhook-secret"
        )
          @api_key = api_key
          @token = token
          @username = username
          @password = password
          @webhook_secret = webhook_secret
        end
      end

      class FakeOperation
        ATTRIBUTES = %i[amount id provider_operation_key payout_requisite].freeze
        attr_accessor(*ATTRIBUTES)

        def initialize(amount: nil, id: nil, provider_operation_key: nil, payout_requisite: nil)
          @amount = amount
          @id = id
          @provider_operation_key = provider_operation_key
          @payout_requisite = payout_requisite
        end
      end

      class FakeResponse
        attr_reader :status, :body, :headers

        def initialize(status:, body: {}, headers: {})
          @status = status
          @body = body
          @headers = headers
        end
      end

      class FakeClient
        attr_reader :calls

        def initialize
          @responses = []
          @calls = []
        end

        def enqueue_response(response)
          @responses << response
          self
        end

        def last_call = calls.last

        def reset!
          @responses.clear
          @calls.clear
          self
        end

        HTTP_METHODS.each do |method|
          define_method(method) do |path, *args, **kwargs|
            request(method, path, args, kwargs)
          end
        end

        private

        def request(method, path, args, kwargs)
          raise "No fake response queued" if @responses.empty?

          @calls << {
            "method" => method.upcase,
            "path" => path,
            "args" => args,
            "kwargs" => kwargs
          }
          @responses.shift
        end
      end

      def load(generated_integration, credentials: nil)
        sandbox = Module.new
        client = FakeClient.new
        credentials ||= FakeCredentials.new
        provider = build_provider_module
        base_service = provider.const_get(:BaseService, false)
        sandbox.const_set(:Provider, provider)
        source = generated_integration.service_code
        filename = generated_integration.service_filename || "(generated)"
        sandbox.module_eval(source, filename, 1)

        top_level_candidates = sandbox.constants(false).filter_map do |name|
          value = sandbox.const_get(name, false)
          value if value.is_a?(Class)
        end
        infrastructure = [
          base_service,
          provider.const_get(:RateLimitError, false),
          provider.const_get(:UnauthorizedError, false)
        ]
        provider_candidates = provider.constants(false).filter_map do |name|
          value = provider.const_get(name, false)
          value if value.is_a?(Class) && !infrastructure.include?(value)
        end
        candidates = (top_level_candidates + provider_candidates).uniq
        service_classes = candidates.select { |klass| klass < base_service }
        context = context_hash(sandbox, provider, base_service, client, credentials, candidates)

        if service_classes.empty?
          return failure(
            :generated_service_class_not_found,
            "No generated BaseService subclass was found",
            filename,
            value: context
          )
        end
        if service_classes.size > 1
          return failure(
            :generated_service_class_ambiguous,
            "More than one generated BaseService subclass was found",
            filename,
            value: context,
            metadata: { "count" => service_classes.size }
          )
        end

        klass = service_classes.first
        context["service_class"] = klass
        context["service"] = instantiate(klass, client, credentials)
        ProviderCompiler::Core::Result.success(context)
      rescue SyntaxError, StandardError => error
        failure(
          :generated_service_load_error,
          "Generated service could not be loaded: #{error.class}: #{error.message}",
          generated_integration.respond_to?(:service_filename) ? generated_integration.service_filename : "(generated)",
          metadata: { "exception_class" => error.class.name }
        )
      end

      def build_operation(**attributes)
        allowed = attributes.each_with_object({}) do |(key, value), result|
          symbol = key.to_sym
          result[symbol] = deep_copy(value) if FakeOperation::ATTRIBUTES.include?(symbol)
        end
        FakeOperation.new(**allowed)
      end

      def build_response(status:, body: {}, headers: {})
        FakeResponse.new(status: status, body: deep_copy(body), headers: deep_copy(headers))
      end

      private

      def build_provider_module
        provider = Module.new
        base_service = Class.new do
          attr_reader :client, :credentials, :actions

          def initialize(client:, credentials:)
            @client = client
            @credentials = credentials
            @actions = []
          end

          def success(result: nil, **details)
            { "success" => true, "result" => result, "data" => details }
          end

          def failure(code = nil, message = nil, **details)
            { "success" => false, "code" => code, "message" => message, "data" => details }
          end

          def approve_operation(*args, **kwargs)
            @actions << { "type" => "approve", "args" => args, "kwargs" => kwargs }
            success(result: args.first, **kwargs)
          end

          def reject_operation(*args, **kwargs)
            @actions << { "type" => "reject", "args" => args, "kwargs" => kwargs }
            success(result: args.first, **kwargs)
          end

          def reset_actions!
            @actions.clear
          end
        end
        provider.const_set(:BaseService, base_service)
        provider.const_set(:RateLimitError, Class.new(StandardError))
        provider.const_set(:UnauthorizedError, Class.new(StandardError))
        provider
      end

      def instantiate(klass, client, credentials)
        klass.new(client: client, credentials: credentials)
      rescue StandardError => error
        raise InstantiationError, "#{error.class}: #{error.message}"
      end

      InstantiationError = Class.new(StandardError)

      def context_hash(sandbox, provider, base_service, client, credentials, candidates)
        {
          "sandbox" => sandbox,
          "provider" => provider,
          "fake_base_service" => base_service,
          "candidate_classes" => candidates,
          "service_class" => nil,
          "service" => nil,
          "client" => client,
          "credentials" => credentials
        }
      end

      def failure(code, message, location, value: nil, metadata: {})
        actual_code = code
        if metadata["exception_class"] == "ProviderCompiler::Verification::Runtime::InstantiationError"
          actual_code = :generated_service_instantiation_error
        end
        diagnostic = ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: actual_code,
          message: message,
          stage: :verification,
          state: :unresolved,
          location: location,
          metadata: metadata
        )
        ProviderCompiler::Core::Result.failure(value, diagnostics: [diagnostic])
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
    end
  end
end
