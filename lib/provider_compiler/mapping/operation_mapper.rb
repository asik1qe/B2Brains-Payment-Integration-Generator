# frozen_string_literal: true

require_relative "match_result"
require_relative "operation_rules"
require_relative "../core/space_payments_contract"

module ProviderCompiler
  module Mapping
    class OperationMapper
      AUTO_THRESHOLD = 55
      REVIEW_THRESHOLD = 35
      AUTO_MARGIN = 12

      def initialize(rules: OperationRules.new)
        @rules = rules
      end

      def call(provider_spec)
        ProviderCompiler::Core::SpacePaymentsContract::OPERATION_ROLES.each_with_object({}) do |role, result|
          ranked = provider_spec.operations.map do |operation|
            assessment = @rules.score(operation, role)
            { candidate: operation, score: assessment[:score], evidence: assessment[:evidence] }
          end.sort_by { |item| [-item[:score], operation_key(item[:candidate])] }

          best = ranked.first
          second_score = ranked[1]&.fetch(:score, 0) || 0
          decision = decision_for(best&.fetch(:score, 0) || 0, second_score, ranked.empty?)
          alternatives = ranked.drop(1).map do |item|
            { "candidate" => item[:candidate], "score" => item[:score], "evidence" => item[:evidence] }
          end
          result[role] = MatchResult.new(
            candidate: best&.fetch(:candidate),
            score: best&.fetch(:score, 0) || 0,
            evidence: best&.fetch(:evidence, []) || [],
            decision: decision,
            alternatives: alternatives,
            metadata: { "margin" => best ? best[:score] - second_score : 0 }
          )
        end
      end

      private

      def decision_for(best_score, second_score, empty)
        return :unresolved if empty || best_score < REVIEW_THRESHOLD
        return :auto if best_score >= AUTO_THRESHOLD && best_score - second_score >= AUTO_MARGIN

        :needs_review
      end

      def operation_key(operation)
        [operation.path.to_s, operation.http_method.to_s, operation.operation_id.to_s].join("|")
      end
    end
  end
end
