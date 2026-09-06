# frozen_string_literal: true

require_relative "errors"
require "yaml"
require "pathname"

module ProviderCompiler
  class Configuration
    DEFAULT_CONFIG_PATH = "provider-compiler.yml"
    CONFIG_KEYS = {
      "spec" => :spec_path,
      "provider" => :provider_name,
      "output" => :output_dir,
      "overrides" => :overrides_path,
      "debug" => :debug
    }.freeze
    ATTRIBUTES = %i[spec_path provider_name output_dir overrides_path].freeze

    attr_reader(*ATTRIBUTES)

    def self.resolve(cli_values, cwd: Dir.pwd)
      values = cli_values.respond_to?(:to_h) ? cli_values.to_h : cli_values.dup
      explicit_path = values[:config_path]
      config_path = if explicit_path
                      pathname = Pathname.new(explicit_path)
                      pathname.absolute? ? explicit_path : File.join(cwd, explicit_path)
                    else
                      File.join(cwd, DEFAULT_CONFIG_PATH)
                    end
      config = if explicit_path || File.file?(config_path)
                 load_config(config_path)
               else
                 {}
               end

      resolved = config.merge(values.reject { |_key, value| value.nil? })
      resolved[:config_path] = config_path if explicit_path || File.file?(config_path)
      resolved
    end

    def self.load_config(path)
      raise ProviderCompiler::ConfigurationError, "Config file not found: #{path}" unless File.file?(path)

      document = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false)
      document = {} if document.nil?
      raise ProviderCompiler::ConfigurationError, "Config root must be an object" unless document.is_a?(Hash)

      document.each_with_object({}) do |(key, value), result|
        attribute = CONFIG_KEYS[key.to_s]
        next unless attribute

        valid = attribute == :debug ? [true, false].include?(value) : value.is_a?(String)
        raise ProviderCompiler::ConfigurationError, "Invalid config value for #{key}" unless valid

        result[attribute] = value
      end
    rescue ProviderCompiler::ConfigurationError
      raise
    rescue StandardError => error
      raise ProviderCompiler::ConfigurationError, "Unable to load config: #{error.message}"
    end

    def self.default_overrides_path(provider_name)
      safe = provider_name.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "")
      File.join(".provider-compiler", "#{safe}.overrides.yml")
    end

    def initialize(spec_path:, provider_name:, output_dir: "./output", overrides_path: nil)
      @spec_path = required_string(spec_path, :spec_path)
      @provider_name = required_string(provider_name, :provider_name)
      @output_dir = required_string(output_dir, :output_dir)
      @overrides_path = optional_string(overrides_path, :overrides_path)
      freeze
    end

    def overrides? = !overrides_path.nil?

    def to_h
      ATTRIBUTES.to_h { |attribute| [attribute, public_send(attribute)] }
    end

    def ==(other)
      other.instance_of?(self.class) && to_h == other.to_h
    end

    alias eql? ==

    def hash = [self.class, to_h].hash

    private

    def required_string(value, attribute)
      return value if value.is_a?(String) && !value.strip.empty?

      raise ProviderCompiler::ConfigurationError, "#{attribute} must be a non-empty String"
    end

    def optional_string(value, attribute)
      return nil if value.nil?

      required_string(value, attribute)
    end
  end
end
