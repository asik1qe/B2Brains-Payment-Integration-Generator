# frozen_string_literal: true

module ProviderCompiler
  module Mapping
    class MatchResult
      DECISIONS = %w[auto needs_review unresolved manual].freeze
      ATTRIBUTES = %i[candidate score evidence decision alternatives metadata].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(candidate:, score:, evidence: [], decision:, alternatives: [], metadata: {})
        raise ArgumentError, "score must be Numeric" unless score.is_a?(Numeric)

        normalized_decision = decision.to_s.downcase
        raise ArgumentError, "unknown decision: #{decision.inspect}" unless DECISIONS.include?(normalized_decision)

        @candidate = candidate
        @score = score
        @evidence = copy(evidence)
        @decision = normalized_decision
        @alternatives = copy(alternatives)
        @metadata = copy(metadata)
      end

      def auto? = decision == "auto"
      def needs_review? = decision == "needs_review"
      def unresolved? = decision == "unresolved"
      def manual? = decision == "manual"
      def resolved? = !unresolved?

      def to_h
        ATTRIBUTES.each_with_object({}) do |attribute, result|
          result[attribute] = serialize(public_send(attribute))
        end
      end

      def ==(other)
        other.instance_of?(self.class) && to_h == other.to_h
      end

      alias eql? ==

      def hash = [self.class, to_h].hash

      private

      def copy(value)
        case value
        when Array then value.map { |item| copy(item) }
        when Hash then value.each_with_object({}) { |(key, item), result| result[key] = copy(item) }
        else value
        end
      end

      def serialize(value)
        case value
        when Array then value.map { |item| serialize(item) }
        when Hash then value.each_with_object({}) { |(key, item), result| result[key] = serialize(item) }
        else value.respond_to?(:to_h) ? value.to_h : value
        end
      end
    end
  end
end
