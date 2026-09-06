# frozen_string_literal: true

module ProviderCompiler
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class CliError < Error; end
  class UserAbort < Error; end
end
