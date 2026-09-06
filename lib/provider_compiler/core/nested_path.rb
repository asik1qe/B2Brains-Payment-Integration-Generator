# frozen_string_literal: true

module ProviderCompiler
  module Core
    module NestedPath
      module_function

      def segments(path)
        path.to_s.split(".").reject(&:empty?)
      end

      def put(target, path, value)
        keys = segments(path)
        return target if keys.empty?

        leaf = keys.pop
        parent = keys.reduce(target) do |current, key|
          existing = current[key]
          raise ArgumentError, "path parent #{key.inspect} is not an object" if existing && !existing.is_a?(Hash)

          current[key] = {} unless existing
          current[key]
        end
        parent[leaf] = value
        target
      end

      def fetch(target, path)
        segments(path).reduce(target) do |current, key|
          break nil unless current.is_a?(Hash)

          current.key?(key) ? current[key] : current[key.to_sym]
        end
      end

      def delete(target, path)
        keys = segments(path)
        return target if keys.empty?

        leaf = keys.pop
        parent = keys.reduce(target) do |current, key|
          break nil unless current.is_a?(Hash)

          current.key?(key) ? current[key] : current[key.to_sym]
        end
        parent.delete(leaf) if parent.is_a?(Hash)
        target
      end
    end
  end
end
