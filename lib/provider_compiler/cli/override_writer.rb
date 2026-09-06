# frozen_string_literal: true

require "fileutils"
require "yaml"
require_relative "../errors"

module ProviderCompiler
  module CLI
    class OverrideWriter
      def initialize(path)
        @path = path
      end

      def operation(role, operation)
        update("operations", role.to_s, {
          "method" => operation.http_method,
          "path" => operation.path
        })
      end

      def field(internal_path, provider_path:, direction: "request", transformation: nil, required: nil)
        patch = { "provider_path" => provider_path, "direction" => direction }
        patch["transformation"] = transformation unless transformation.nil?
        patch["required"] = required unless required.nil?
        update_field(internal_path.to_s, patch)
      end

      def webhook(patch)
        data = load_data
        data["webhook"] = {} unless data["webhook"].is_a?(Hash)
        data["webhook"] = data["webhook"].merge(stringify(patch))
        write(data)
      end

      def security(mapping)
        data = load_data
        data["security"] = {
          "scheme_key" => mapping.fetch("scheme_key"),
          "type" => mapping.fetch("type"),
          "location" => mapping["location"],
          "name" => mapping["name"],
          "credential_path" => mapping["credential_path"],
          "prefix" => mapping["prefix"],
          "parameters" => mapping["parameters"] || {}
        }.compact
        write(data)
      end

      private

      def update(section, key, patch)
        data = load_data
        data[section] = {} unless data[section].is_a?(Hash)
        current = data[section][key]
        current = {} unless current.is_a?(Hash)
        data[section][key] = current.merge(patch)
        write(data)
      end

      # A single Space Payments field may legitimately feed more than one
      # provider field. Preserve every explicit user decision instead of
      # overwriting the previous binding and reopening the same review loop.
      # Legacy single-binding overrides remain stored as a Hash; collisions
      # are promoted to an Array of patches.
      def update_field(key, patch)
        data = load_data
        data["fields"] = {} unless data["fields"].is_a?(Hash)
        current = data["fields"][key]

        entries = case current
                  when Array then current.map { |item| item.is_a?(Hash) ? item : {} }
                  when Hash then [current]
                  else []
                  end
        identity = [patch["provider_path"].to_s, patch["direction"].to_s.downcase]
        index = entries.index do |item|
          [item["provider_path"].to_s, item.fetch("direction", "request").to_s.downcase] == identity
        end

        if index
          entries[index] = entries[index].merge(patch)
        else
          entries << patch
        end

        data["fields"][key] = entries.length == 1 ? entries.first : entries
        write(data)
      end

      def load_data
        return {} unless File.file?(@path)

        value = YAML.safe_load(File.read(@path, encoding: "UTF-8"), aliases: false)
        value = {} if value.nil?
        raise ProviderCompiler::ConfigurationError, "Overrides root must be an object" unless value.is_a?(Hash)

        stringify(value)
      rescue Psych::Exception => error
        raise ProviderCompiler::ConfigurationError, "Unable to load overrides: #{error.message}"
      end

      def write(data)
        directory = File.dirname(@path)
        FileUtils.mkdir_p(directory) unless directory == "."
        temporary = "#{@path}.tmp-#{Process.pid}"
        File.write(temporary, YAML.dump(deep_sort(data)), mode: "w", encoding: "UTF-8")
        File.rename(temporary, @path)
      ensure
        File.delete(temporary) if defined?(temporary) && File.file?(temporary)
      end

      def deep_sort(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
            item = value.key?(key) ? value[key] : value[key.to_sym]
            result[key] = deep_sort(item)
          end
        when Array
          value.map { |item| deep_sort(item) }
        else
          value
        end
      end

      def stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
        when Array
          value.map { |item| stringify(item) }
        else
          value
        end
      end
    end
  end
end
