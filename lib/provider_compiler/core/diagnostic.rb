# frozen_string_literal: true

module ProviderCompiler
  module Core
    class Diagnostic
      SEVERITIES = %w[info warning error].freeze
      ATTRIBUTES = %i[severity code message stage location state metadata].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(severity:, code:, message:, stage: nil, location: nil, state: nil, metadata: {})
        raise ArgumentError, "severity must not be empty" if empty?(severity)
        raise ArgumentError, "code must not be empty" if empty?(code)
        raise ArgumentError, "message must not be empty" if empty?(message)
        raise ArgumentError, "metadata must be a Hash" unless metadata.is_a?(Hash)

        normalized_severity = severity.to_s.downcase
        unless SEVERITIES.include?(normalized_severity)
          raise ArgumentError, "unknown severity: #{severity.inspect}"
        end

        @severity = normalized_severity
        @code = code.to_s
        @message = message
        @stage = stage&.to_s
        @location = copy_collection(location)
        @state = state&.to_s&.downcase
        @metadata = copy_collection(metadata)
      end

      def info? = severity == "info"
      def warning? = severity == "warning"
      def error? = severity == "error"
      def needs_review? = state == "needs_review"
      def unresolved? = state == "unresolved"
      def blocking? = error? || unresolved?

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

      def empty?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      def copy_collection(value)
        case value
        when Array
          value.map { |item| copy_collection(item) }
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key] = copy_collection(item) }
        else
          value
        end
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
