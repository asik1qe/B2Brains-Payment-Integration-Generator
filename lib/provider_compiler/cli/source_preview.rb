# frozen_string_literal: true

require "yaml"

module ProviderCompiler
  module CLI
    class SourcePreview
      def initialize(path)
        @document = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false) || {}
      rescue StandardError
        @document = {}
      end

      def operations(candidates)
        paths = @document.fetch("paths", {})
        fragment = candidates.each_with_object({}) do |operation, result|
          raw = paths[operation.path]
          next unless raw.is_a?(Hash)

          item = raw[operation.http_method.downcase]
          result["#{operation.http_method} #{operation.path}"] = item if item
        end
        render(fragment)
      end

      def fields(paths)
        requested = Array(paths).map(&:to_s)
        matches = {}
        schemas = @document.dig("components", "schemas") || @document.dig("definitions") || {}
        schemas.each_value { |schema| find_fields(resolve(schema), requested, matches) }
        render("properties" => matches)
      end

      private

      def find_fields(schema, requested, matches, prefix = nil)
        return unless schema.is_a?(Hash)

        properties = resolve(schema)["properties"]
        return unless properties.is_a?(Hash)

        properties.each do |name, value|
          path = [prefix, name].compact.join(".")
          resolved = resolve(value)
          matches[path] = compact_schema(resolved) if requested.include?(path) || requested.include?(name.to_s)
          find_fields(resolved, requested, matches, path)
        end
      end

      def resolve(value)
        return value unless value.is_a?(Hash) && value["$ref"].to_s.start_with?("#/")

        value["$ref"].delete_prefix("#/").split("/").reduce(@document) do |node, token|
          node.is_a?(Hash) ? node[token.gsub("~1", "/").gsub("~0", "~")] : nil
        end || value
      end

      def compact_schema(schema)
        return schema unless schema.is_a?(Hash)

        schema.select { |key, _| %w[type description enum format pattern minimum maximum required properties].include?(key) }
      end

      def render(fragment)
        return "Source fragment unavailable." if fragment.empty? || fragment == { "properties" => {} }

        YAML.dump(fragment).sub(/\A---\s*\n/, "").rstrip
      end
    end
  end
end
