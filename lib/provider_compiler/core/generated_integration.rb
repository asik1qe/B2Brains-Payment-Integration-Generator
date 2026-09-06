# frozen_string_literal: true

module ProviderCompiler
  module Core
    class GeneratedIntegration
      ATTRIBUTES = %i[
        service_code integration_markdown fixtures_json service_filename integration_filename
        fixtures_filename provider_name metadata
      ].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(
        service_code:,
        integration_markdown:,
        fixtures_json:,
        service_filename: nil,
        integration_filename: "INTEGRATION.md",
        fixtures_filename: "fixtures.json",
        provider_name: nil,
        metadata: {}
      )
        validate_string!(service_code, :service_code)
        validate_string!(integration_markdown, :integration_markdown)
        validate_string!(fixtures_json, :fixtures_json)
        validate_optional_string!(service_filename, :service_filename)
        validate_optional_string!(integration_filename, :integration_filename)
        validate_optional_string!(fixtures_filename, :fixtures_filename)
        validate_optional_string!(provider_name, :provider_name, allow_empty: true)
        raise ArgumentError, "metadata must be a Hash" unless metadata.is_a?(Hash)

        @service_code = service_code
        @integration_markdown = integration_markdown
        @fixtures_json = fixtures_json
        @service_filename = service_filename
        @integration_filename = integration_filename
        @fixtures_filename = fixtures_filename
        @provider_name = provider_name
        @metadata = copy_collection(metadata)
      end

      def files
        [service_file, documentation_file, fixtures_file].compact.to_h do |entry|
          [entry[:filename], entry[:content]]
        end
      end

      def file(name)
        files[name.to_s]
      end

      def service_file
        file_entry(service_filename, service_code)
      end

      def documentation_file
        file_entry(integration_filename, integration_markdown)
      end

      def fixtures_file
        file_entry(fixtures_filename, fixtures_json)
      end

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

      def validate_string!(value, attribute)
        return if value.is_a?(String)

        raise ArgumentError, "#{attribute} must be a String"
      end

      def validate_optional_string!(value, attribute, allow_empty: false)
        return if value.nil?

        validate_string!(value, attribute)
        return if allow_empty || !value.empty?

        raise ArgumentError, "#{attribute} must not be empty"
      end

      def file_entry(filename, content)
        return nil if filename.nil?

        { filename: filename, content: content }
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
