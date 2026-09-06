# frozen_string_literal: true

module ProviderCompiler
  module CLI
    class ReviewClassifier
      REVIEWABLE_CODES = %w[
        critical_operation_mapping_needs_review
        field_mapping_needs_review
        field_mapping_unresolved
        transformation_incomplete
        payout_requisite_mapping_unresolved
        security_mapping_needs_review
        webhook_field_mapping_unresolved
      ].freeze

      def reviewable(diagnostics)
        diagnostics.select { |diagnostic| REVIEWABLE_CODES.include?(diagnostic.code) }
      end

      def fatal(diagnostics)
        reviewable_ids = reviewable(diagnostics).map(&:object_id)
        diagnostics.select(&:blocking?).reject { |diagnostic| reviewable_ids.include?(diagnostic.object_id) }
      end
    end
  end
end
