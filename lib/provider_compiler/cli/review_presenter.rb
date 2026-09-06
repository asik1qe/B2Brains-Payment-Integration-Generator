# frozen_string_literal: true

module ProviderCompiler
  module CLI
    class ReviewPresenter
      attr_reader :out

      def initialize(out: $stdout)
        @out = out
      end

      def heading(label, index:, total:)
        out.puts("\nREVIEW #{index}/#{total} — #{label}\n")
      end

      def problem(message)
        out.puts(message)
      end

      def candidates(items, formatter:, suggested: true)
        out.puts("\nCandidates:\n")
        if items.empty?
          out.puts("  (none detected)")
        else
          items.each_with_index { |item, index| out.puts("  [#{index + 1}] #{formatter.call(item)}") }
        end
        out.puts("\nSuggested:\n  [1] #{formatter.call(items.first)}") if suggested && !items.empty?
      end

      def source_question
        out.puts("\nShow original OpenAPI fragment? [y/N]")
      end

      def source(fragment)
        out.puts("\nOpenAPI source:\n#{fragment}\n")
      end

      def choose(count, manual_label:)
        choices = ["\nChoose:"]
        choices << "  1-#{count}  select" if count.positive?
        choices << "  m    #{manual_label}" if manual_label
        choices << "  q    abort"
        out.puts(choices.join("\n"))
      end

      def prompt(label = nil)
        out.puts(label) if label
        out.print("> ")
      end

      def saved(text, path)
        out.puts("\nSaved:\n  #{text}\nOverrides:\n  #{path}")
      end

      def invalid(message)
        out.puts(message)
      end
    end
  end
end
