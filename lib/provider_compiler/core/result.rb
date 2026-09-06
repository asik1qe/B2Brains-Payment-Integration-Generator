# frozen_string_literal: true

require_relative "diagnostic"

module ProviderCompiler
  module Core
    class Result
      ATTRIBUTES = %i[value diagnostics].freeze

      attr_reader(*ATTRIBUTES)

      def self.success(value = nil, diagnostics: [])
        result = new(value: value, diagnostics: diagnostics)
        raise ArgumentError, "success result cannot contain blocking diagnostics" if result.failure?

        result
      end

      def self.failure(value = nil, diagnostics:)
        result = new(value: value, diagnostics: diagnostics)
        raise ArgumentError, "failure result requires a blocking diagnostic" if result.success?

        result
      end

      def initialize(value: nil, diagnostics: [])
        @value = value
        @diagnostics = diagnostics.dup
      end

      def success?
        blocking_diagnostics.empty?
      end

      def failure? = !success?

      def errors
        diagnostics.select { |diagnostic| predicate?(diagnostic, :error?) }
      end

      def warnings
        diagnostics.select { |diagnostic| predicate?(diagnostic, :warning?) }
      end

      def infos
        diagnostics.select { |diagnostic| predicate?(diagnostic, :info?) }
      end

      def blocking_diagnostics
        diagnostics.select { |diagnostic| predicate?(diagnostic, :blocking?) }
      end

      def needs_review?
        diagnostics.any? { |diagnostic| predicate?(diagnostic, :needs_review?) }
      end

      def unresolved?
        diagnostics.any? { |diagnostic| predicate?(diagnostic, :unresolved?) }
      end

      def with_diagnostic(diagnostic)
        self.class.new(value: value, diagnostics: diagnostics + [diagnostic])
      end

      def to_h
        ATTRIBUTES.each_with_object({}) do |attribute, result|
          result[attribute] = serialize(public_send(attribute))
        end
      end

      def ==(other)
        other.instance_of?(self.class) && to_h == other.to_h
      end

      alias eql? ==

      def hash
        [self.class, to_h].hash
      end

      private

      def predicate?(diagnostic, predicate)
        diagnostic.respond_to?(predicate) && diagnostic.public_send(predicate)
      end

      def serialize(value)
        case value
        when Array
          value.map { |item| serialize(item) }
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key] = serialize(item) }
        else
          serializable_core_object?(value) ? value.to_h : value
        end
      end

      def serializable_core_object?(value)
        value.respond_to?(:to_h) && value.class.name.to_s.start_with?("ProviderCompiler::Core::")
      end
    end
  end
end
