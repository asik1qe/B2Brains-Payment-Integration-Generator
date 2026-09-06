# frozen_string_literal: true

require "rspec/core/formatters"

module ProviderCompiler
  module Spec
    class SuiteFormatter
      RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending, :dump_summary

      ORDER = %w[unit pipeline acceptance real_world].freeze
      LABELS = {
        "unit" => "UNIT",
        "pipeline" => "PIPELINE",
        "acceptance" => "ACCEPTANCE",
        "real_world" => "REAL-WORLD OPENAPI"
      }.freeze

      def initialize(output)
        @output = output
        @stats = Hash.new { |hash, key| hash[key] = empty_row }
        @components = Hash.new { |hash, key| hash[key] = empty_row }
      end

      def example_passed(notification)
        record(notification.example, :passed)
      end

      def example_failed(notification)
        record(notification.example, :failed)
      end

      def example_pending(notification)
        record(notification.example, :pending)
      end

      def dump_summary(notification)
        @output.puts
        @output.puts("=" * 78)
        @output.puts("PROVIDER COMPILER TEST REPORT")
        @output.puts("=" * 78)

        ORDER.each { |suite| print_row(LABELS.fetch(suite), @stats[suite]) }

        uncategorized = @stats.keys - ORDER
        uncategorized.sort.each { |suite| print_row(suite.upcase, @stats[suite]) }

        @output.puts("-" * 78)
        total = aggregate(@stats.values)
        print_row("TOTAL", total)

        @output.puts
        @output.puts("Unit coverage by component:")
        @components.keys.sort.each do |component|
          print_row("  #{component}", @components[component])
        end

        @output.puts
        status = if notification.failure_count.positive?
                   "FAIL"
                 elsif notification.pending_count.positive?
                   "PASS WITH PENDING"
                 else
                   "PASS"
                 end
        @output.puts(format(
          "RESULT: %s | runtime: %.2fs | examples: %d | failures: %d | pending: %d",
          status,
          notification.duration,
          notification.example_count,
          notification.failure_count,
          notification.pending_count
        ))
        @output.puts("=" * 78)
      end

      private

      def empty_row
        { passed: 0, failed: 0, pending: 0 }
      end

      def record(example, state)
        suite = (example.metadata[:suite] || :uncategorized).to_s
        @stats[suite][state] += 1

        return unless suite == "unit"

        component = (example.metadata[:component] || :other).to_s
        @components[component][state] += 1
      end

      def aggregate(rows)
        rows.each_with_object(empty_row) do |row, total|
          total.each_key { |key| total[key] += row.fetch(key) }
        end
      end

      def print_row(label, row)
        total = row.values.sum
        @output.puts(format(
          "%-24s %4d/%-4d passed | %3d failed | %3d pending",
          label,
          row[:passed],
          total,
          row[:failed],
          row[:pending]
        ))
      end
    end
  end
end
