# frozen_string_literal: true

require "bundler/setup"
require "provider_compiler"
require_relative "support/paths"
require_relative "support/cli_runner"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # Keep suite reporting deterministic on Windows and Unix. RSpec normally
  # uses forward slashes, but normalize defensively before deriving metadata.
  config.define_derived_metadata do |metadata|
    path = metadata[:file_path].to_s.tr("\\", "/")

    case path
    when %r{/spec/unit/([^/]+)/}
      metadata[:suite] ||= :unit
      metadata[:component] ||= Regexp.last_match(1).to_sym
    when %r{/spec/pipeline/}
      metadata[:suite] ||= :pipeline
    when %r{/spec/acceptance/}
      metadata[:suite] ||= :acceptance
    when %r{/spec/real_world/}
      metadata[:suite] ||= :real_world
    end
  end
end
