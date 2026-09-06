# frozen_string_literal: true

require_relative "../configuration"
require_relative "../core/space_payments_contract"
require_relative "../mapping/operation_mapper"
require_relative "../mapping/webhook_mapper"
require_relative "review_classifier"
require_relative "review_presenter"
require_relative "source_preview"
require_relative "override_writer"

module ProviderCompiler
  module CLI
    class ReviewSession
      Result = Struct.new(:status, :mapping_result, :configuration, keyword_init: true)

      def initialize(compiler:, input:, out:, classifier: ReviewClassifier.new, debug: false)
        @compiler = compiler
        @input = input
        @presenter = ReviewPresenter.new(out: out)
        @classifier = classifier
        @debug = debug
      end

      def run(provider_spec:, mapping_result:, configuration:, overrides_path:)
        current = mapping_result
        current_configuration = configuration
        preview = SourcePreview.new(configuration.spec_path)
        decisions = 0

        loop do
          return Result.new(status: :fatal, mapping_result: current, configuration: current_configuration) unless
            @classifier.fatal(current.diagnostics).empty?

          reviews = @classifier.reviewable(current.diagnostics)
          return Result.new(status: :resolved, mapping_result: current, configuration: current_configuration) if reviews.empty?

          diagnostic = reviews.first
          decision = review(
            diagnostic,
            plan: current.value,
            provider_spec: provider_spec,
            preview: preview,
            index: decisions + 1,
            total: decisions + reviews.length
          )
          return Result.new(status: :aborted, mapping_result: current, configuration: current_configuration) if decision == :abort

          save(decision, overrides_path)
          decisions += 1
          current_configuration = ProviderCompiler::Configuration.new(
            spec_path: configuration.spec_path,
            provider_name: configuration.provider_name,
            output_dir: configuration.output_dir,
            overrides_path: overrides_path
          )
          @presenter.out.puts("\nMapping: rerun after saved decision") if @debug
          current = @compiler.map(provider_spec, current_configuration)
        end
      end

      private

      def review(diagnostic, plan:, provider_spec:, preview:, index:, total:)
        case diagnostic.code
        when "critical_operation_mapping_needs_review"
          review_operation(diagnostic, plan, provider_spec, preview, index, total)
        when "field_mapping_needs_review", "field_mapping_unresolved"
          review_field(diagnostic, plan, provider_spec, preview, index, total)
        when "transformation_incomplete"
          review_money(diagnostic, plan, preview, index, total)
        when "payout_requisite_mapping_unresolved"
          review_requisite(diagnostic, preview, index, total)
        when "security_mapping_needs_review"
          review_security(diagnostic, plan, index, total)
        when "webhook_field_mapping_unresolved"
          review_webhook_field(diagnostic, plan, index, total)
        else
          :abort
        end
      end

      def review_operation(diagnostic, plan, provider_spec, preview, index, total)
        role = diagnostic.location.to_s
        mapping = plan.operations[role]
        alternatives = Array(mapping&.metadata&.fetch("alternatives", [])).select do |item|
          (item["score"] || item[:score]).to_f >= ProviderCompiler::Mapping::OperationMapper::REVIEW_THRESHOLD
        end
        candidates = [mapping&.operation, *alternatives.map { |item| item["candidate"] || item[:candidate] }].compact
        candidates = candidates.uniq { |item| [item.http_method, item.path] }
        scores = { [mapping.operation.http_method, mapping.operation.path] => mapping.score }
        alternatives.each do |item|
          operation = item["candidate"] || item[:candidate]
          scores[[operation.http_method, operation.path]] = item["score"] || item[:score] if operation
        end
        formatter = lambda do |operation|
          details = "#{operation.http_method} #{operation.path}"
          details += " (operationId: #{operation.operation_id})" if operation.operation_id
          details += " score: #{scores[[operation.http_method, operation.path]]}" if scores[[operation.http_method, operation.path]]
          details
        end
        @presenter.heading(role, index: index, total: total)
        @presenter.problem("The endpoint could not be selected unambiguously.")
        @presenter.candidates(candidates, formatter: formatter)
        return :abort if maybe_preview { preview.operations(candidates) } == :abort

        loop do
          @presenter.choose(candidates.length, manual_label: "manual endpoint")
          answer = read_answer
          return :abort if answer.nil? || answer.casecmp?("q")
          if answer.casecmp?("m")
            operation = manual_operation(provider_spec)
            return :abort if operation == :abort
            next unless operation

            return { type: :operation, role: role, operation: operation }
          end
          selected = numbered(answer, candidates)
          return { type: :operation, role: role, operation: selected } if selected

          @presenter.invalid("Choose a candidate number, m, or q.")
        end
      end

      def review_field(diagnostic, plan, provider_spec, preview, index, total)
        internal_path = diagnostic.location.to_s
        mapping = plan.fields.find { |item| item.internal_path == internal_path }
        candidates = [mapping&.provider_path, *Array(mapping&.metadata&.fetch("alternatives", [])).map { |item| item["path"] }]
                     .compact.uniq
        scores = { mapping&.provider_path => mapping&.score }
        Array(mapping&.metadata&.fetch("alternatives", [])).each { |item| scores[item["path"]] = item["score"] }
        formatter = ->(path) { scores[path] ? "#{path} score: #{scores[path]}" : path }
        @presenter.heading(internal_path, index: index, total: total)
        @presenter.problem("The provider field could not be mapped unambiguously.")
        @presenter.candidates(candidates, formatter: formatter)
        return :abort if maybe_preview { preview.fields(candidates) } == :abort

        loop do
          @presenter.choose(candidates.length, manual_label: "enter provider path manually")
          answer = read_answer
          return :abort if answer.nil? || answer.casecmp?("q")
          provider_path = if answer.casecmp?("m")
                            candidate = prompt_nonempty("Provider path:")
                            if candidate != :abort && !provider_field_path?(provider_spec, candidate)
                              @presenter.invalid("Provider field was not found in OpenAPI. Try again.")
                              nil
                            else
                              candidate
                            end
                          else
                            numbered(answer, candidates)
                          end
          return :abort if provider_path == :abort
          if provider_path
            return {
              type: :field, internal_path: internal_path, provider_path: provider_path,
              direction: mapping&.direction || "request", transformation: mapping&.transformation,
              required: mapping&.required
            }
          end
          @presenter.invalid("Choose a candidate number, m, or q.")
        end
      end

      def review_money(diagnostic, plan, preview, index, total)
        internal_path = diagnostic.location.to_s
        mapping = plan.fields.find { |item| item.internal_path == internal_path }
        provider_path = diagnostic.metadata["provider_path"] || mapping&.provider_path
        unit = diagnostic.metadata["unit"] || mapping&.transformation&.fetch("unit", nil)
        @presenter.heading(internal_path, index: index, total: total)
        @presenter.problem("Detected provider field: #{provider_path}\nUnit: #{unit}\nFactor: unknown\nThe compiler cannot safely guess the conversion factor.")
        return :abort if maybe_preview { preview.fields(provider_path) } == :abort
        loop do
          answer = prompt_nonempty("Enter integer factor:")
          return :abort if answer == :abort
          factor = Integer(answer, exception: false)
          if factor && factor.positive?
            transformation = (mapping&.transformation || { "type" => "money", "unit" => unit }).merge("factor" => factor)
            return {
              type: :field, internal_path: internal_path, provider_path: provider_path,
              direction: mapping&.direction || "request", transformation: transformation,
              required: mapping&.required
            }
          end
          @presenter.invalid("Factor must be a positive integer.")
        end
      end

      def review_requisite(diagnostic, preview, index, total)
        provider_path = Array(diagnostic.metadata["fields"] || diagnostic.metadata["provider_paths"]).first || diagnostic.location
        known = ProviderCompiler::Core::SpacePaymentsContract::KNOWN_OPERATION_PATHS.select do |path|
          path.start_with?("operation.payout_requisite.") && path != "operation.payout_requisite"
        end
        known = known.sort_by { |path| path.end_with?("card_number") ? 0 : 1 }
        @presenter.heading(provider_path, index: index, total: total)
        @presenter.problem("Provider requires #{provider_path} (required: true).\nThis field has no confirmed Space Payments mapping.")
        @presenter.candidates(known, formatter: ->(path) { path }, suggested: false)
        return :abort if maybe_preview { preview.fields(provider_path) } == :abort

        loop do
          @presenter.choose(known.length, manual_label: "enter internal path manually")
          answer = read_answer
          return :abort if answer.nil? || answer.casecmp?("q")
          internal_path = numbered(answer, known)
          if answer.casecmp?("m")
            internal_path = prompt_nonempty("Internal Space Payments path:")
            return :abort if internal_path == :abort
            unless ProviderCompiler::Core::SpacePaymentsContract.known_operation_path?(internal_path)
              @presenter.invalid("Manual path is outside the confirmed Space Payments contract.\nIt will be marked as MANUAL.")
            end
          end
          return { type: :field, internal_path: internal_path, provider_path: provider_path, direction: "request", required: true } if internal_path

          @presenter.invalid("Choose a candidate number, m, or q.")
        end
      end

      def review_webhook_field(diagnostic, plan, index, total)
        field = (diagnostic.metadata["field"] || diagnostic.location).to_s
        operation = plan.webhook&.operation
        schema = operation&.request_body&.schema
        candidates = schema_leaf_paths(schema)
        aliases = ProviderCompiler::Mapping::WebhookMapper::FIELD_ALIASES[field.to_sym] || []
        candidates = candidates.sort_by do |path|
          leaf = path.to_s.split(".").last.to_s
          [aliases.include?(normalize_field_name(leaf)) ? 0 : 1, path.to_s]
        end

        @presenter.heading("webhook.#{field}", index: index, total: total)
        @presenter.problem("A required callback field could not be mapped safely.")
        @presenter.candidates(candidates, formatter: ->(path) { path }, suggested: false)

        loop do
          @presenter.choose(candidates.length, manual_label: "enter callback provider path manually")
          answer = read_answer
          return :abort if answer.nil? || answer.casecmp?("q")
          provider_path = if answer.casecmp?("m")
                            value = prompt_nonempty("Callback provider path:")
                            return :abort if value == :abort
                            unless candidates.include?(value)
                              @presenter.invalid("Callback field was not found in the selected callback schema.")
                              next
                            end
                            value
                          else
                            numbered(answer, candidates)
                          end
          return { type: :webhook, patch: { field => provider_path } } if provider_path

          @presenter.invalid("Choose a candidate number, m, or q.")
        end
      end

      def review_security(_diagnostic, plan, index, total)
        alternatives = Array(plan.security&.metadata&.fetch("alternatives", [])).map do |item|
          item.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        end
        @presenter.heading("security", index: index, total: total)
        @presenter.problem("Auth mapping requires review.")
        formatter = lambda do |mapping|
          [mapping["scheme_key"], mapping["type"], mapping["location"], mapping["name"]].compact.join(" - ")
        end
        @presenter.candidates(alternatives, formatter: formatter)
        loop do
          @presenter.choose(alternatives.length, manual_label: nil)
          answer = read_answer
          return :abort if answer.nil? || answer.casecmp?("q")
          selected = numbered(answer, alternatives)
          return { type: :security, mapping: selected } if selected

          @presenter.invalid("Choose a candidate number or q.")
        end
      end

      def maybe_preview
        if @debug
          @presenter.source(yield)
          return
        end

        @presenter.source_question
        answer = read_answer
        return :abort if answer.nil? || answer.casecmp?("q")
        @presenter.source(yield) if answer&.casecmp?("y")
        :continue
      end

      def manual_operation(provider_spec)
        loop do
          method = prompt_nonempty("HTTP method:")
          return :abort if method == :abort
          path = prompt_nonempty("Path:")
          return :abort if path == :abort
          operation = provider_spec.operation(http_method: method, path: path)
          return operation if operation

          @presenter.invalid("Operation not found in OpenAPI.\nTry again.")
        end
      end

      def prompt_nonempty(label)
        loop do
          @presenter.prompt(label)
          answer = @input.gets
          return :abort if answer.nil?
          value = answer.strip
          return :abort if value.casecmp?("q")
          return value unless value.empty?

          @presenter.invalid("Value must not be blank.")
        end
      end

      def read_answer
        @presenter.prompt
        @input.gets&.strip
      end

      def numbered(answer, values)
        index = Integer(answer, exception: false)
        return unless index && index.between?(1, values.length)

        values[index - 1]
      end

      def provider_field_path?(provider_spec, requested)
        paths = provider_spec.operations.flat_map do |operation|
          operation.parameters.map { |parameter| parameter.name.to_s } +
            schema_paths(operation.request_body&.schema) +
            operation.responses.values.flat_map { |response| schema_paths(response.schema) }
        end
        paths.include?(requested.to_s)
      end

      def schema_paths(schema, prefix = nil)
        return [] unless schema

        schema.properties.flat_map do |name, child|
          path = [prefix, name].compact.join(".")
          [path] + schema_paths(child, path)
        end
      end

      def schema_leaf_paths(schema, prefix = nil)
        return [] unless schema

        schema.properties.flat_map do |name, child|
          path = [prefix, name].compact.join(".")
          child.properties.any? ? schema_leaf_paths(child, path) : [path]
        end
      end

      def normalize_field_name(value)
        value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase.tr("- ", "__")
      end

      def save(decision, path)
        writer = OverrideWriter.new(path)
        if decision[:type] == :operation
          writer.operation(decision[:role], decision[:operation])
          text = "#{decision[:role]} -> #{decision[:operation].http_method} #{decision[:operation].path}"
        elsif decision[:type] == :field
          writer.field(
            decision[:internal_path], provider_path: decision[:provider_path], direction: decision[:direction],
            transformation: decision[:transformation], required: decision[:required]
          )
          text = "#{decision[:internal_path]} -> #{decision[:provider_path]}"
        elsif decision[:type] == :webhook
          writer.webhook(decision[:patch])
          key, value = decision[:patch].first
          text = "webhook.#{key} -> #{value}"
        else
          writer.security(decision[:mapping])
          text = "security -> #{decision[:mapping]['scheme_key']}"
        end
        @presenter.saved(text, path)
      end
    end
  end
end
