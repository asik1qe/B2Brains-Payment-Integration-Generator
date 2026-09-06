# frozen_string_literal: true

require_relative "../core/diagnostic"

module ProviderCompiler
  module OpenAPI
    class RefResolver
      attr_reader :diagnostics

      def initialize(document)
        @document = document
        @diagnostics = []
      end

      def local_ref?(ref)
        ref.is_a?(String) && ref.start_with?("#/")
      end

      def resolve(ref)
        unless ref.is_a?(String) && !ref.empty?
          return record(:invalid_ref, "Reference must be a non-empty string", ref)
        end

        unless local_ref?(ref)
          code = ref.start_with?("#") ? :invalid_ref : :external_ref_unsupported
          message = code == :invalid_ref ? "Malformed local reference" : "External references are unsupported"
          return record(code, message, ref)
        end

        tokens = pointer_tokens(ref)
        return record(:invalid_ref, "Malformed JSON Pointer reference", ref) if tokens.nil?

        found, value = traverse(tokens)
        return value if found

        record(:ref_not_found, "Reference target was not found", ref)
      rescue StandardError => error
        record(:invalid_ref, "Invalid reference: #{error.message}", ref)
      end

      private

      def pointer_tokens(ref)
        raw_tokens = ref.delete_prefix("#/").split("/", -1)
        return nil if raw_tokens.any? { |token| token.match?(/~(?![01])/) }

        raw_tokens.map { |token| token.gsub("~1", "/").gsub("~0", "~") }
      end

      def traverse(tokens)
        current = @document

        tokens.each do |token|
          case current
          when Hash
            return [false, nil] unless current.key?(token)

            current = current[token]
          when Array
            return [false, nil] unless token.match?(/\A(?:0|[1-9]\d*)\z/)

            index = token.to_i
            return [false, nil] if index >= current.length

            current = current[index]
          else
            return [false, nil]
          end
        end

        [true, current]
      end

      def record(code, message, location)
        diagnostics << ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: code,
          message: message,
          stage: :openapi,
          state: :unresolved,
          location: location
        )
        nil
      end
    end
  end
end
